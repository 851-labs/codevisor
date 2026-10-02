import CodevisorClient
import CodevisorCloud
import Foundation
import Observation
import OSLog
import ScreenSharing
import ScreenSharingWebRTC

/// One simulator's screen streamed from its Mac: the WebRTC receiver negotiated through the
/// machine's `/v1/screen-sharing` route with the target `simulator:<udid>`, kept alive by
/// heartbeats and reconnected after a dropped transport. Input and device state travel on the
/// receiver's simulator channel.
@MainActor
@Observable
public final class SimulatorStreamConnection: SimulatorConnection {
  public private(set) var phase: SimulatorConnectionPhase = .connecting
  /// The receiver frames arrive on; replaced on every reconnect.
  public private(set) var receiver: ScreenSharingReceiver?
  /// What the host says about the device, from its latest state message.
  public private(set) var state: ScreenSharingSimulatorState?
  /// The decoded video's size in pixels, upright as the device is held.
  public private(set) var frameSize: CGSize?

  @ObservationIgnored let udid: String
  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let workspaceId: UUID
  @ObservationIgnored private let paneId: UUID
  @ObservationIgnored private let openTunnel: (@MainActor () async -> CloudTunnelMediaRoute?)?
  @ObservationIgnored private let viewerId = UUID()
  @ObservationIgnored private var runner: Task<Void, Never>?
  @ObservationIgnored private var sequenceReady = false
  private static let log = Logger(subsystem: "com.codevisor.SimulatorPane", category: "Stream")

  public init(
    udid: String, client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID,
    openTunnel: (@MainActor () async -> CloudTunnelMediaRoute?)? = nil
  ) {
    self.udid = udid
    self.client = client
    self.workspaceId = workspaceId
    self.paneId = paneId
    self.openTunnel = openTunnel
  }

  var target: String { "simulator:\(udid)" }

  public var source: SimulatorScreenSource? { receiver.map { .video($0.mailbox, $0.metrics) } }

  public func start() {
    guard runner == nil else { return }
    phase = .connecting
    runner = Task { [weak self] in await self?.run() }
  }

  public func stop() {
    runner?.cancel()
    runner = nil
    closeReceiver()
    let request = request(.stop)
    let client = client
    // A fresh task: the runner's own was just cancelled.
    Task { _ = try? await client.screenSharing(request) }
  }

  /// Sends input or a device command; false while nothing is connected.
  @discardableResult
  public func send(_ message: ScreenSharingSimulatorMessage) -> Bool {
    guard let receiver, receiver.simulatorChannel.isAvailable else { return false }
    return receiver.simulatorChannel.send(message)
  }

  /// Called by the video view as frames reach the screen.
  public func presented(frameSize size: CGSize) {
    if frameSize != size { frameSize = size }
    if phase != .streaming {
      Self.log.info("first frame \(Int(size.width))x\(Int(size.height))")
      phase = .streaming
    }
  }

  private func run() async {
    var restarts = 0
    while !Task.isCancelled {
      let outcome = await attempt(restart: restarts > 0)
      closeReceiver()
      switch outcome {
      case .cancelled:
        return
      case .ended(let message):
        phase = .failed(message)
        runner = nil
        return
      case .lost:
        guard restarts < 12 else {
          phase = .failed("The simulator's connection keeps dropping. Reconnect to try again.")
          runner = nil
          return
        }
        restarts += 1
        phase = .reconnecting
        try? await Task.sleep(for: .seconds(min(6, restarts)))
      }
    }
  }

  private enum Outcome { case cancelled, lost, ended(String) }

  private func attempt(restart: Bool) async -> Outcome {
    var tunnel: CloudTunnelMediaRoute?
    defer { tunnel?.close() }
    do {
      let capabilities = try await client.screenSharing(request(.capabilities))
      try Task.checkCancellation()
      // A device still booting, or whose screen isn't up yet: try again shortly.
      Self.log.info("capabilities \(capabilities.status, privacy: .public)")
      if capabilities.status == "starting" { return .lost }
      guard capabilities.version == 1, capabilities.status == "available" else {
        return .ended(capabilities.message ?? "This simulator isn't available on its Mac.")
      }
      let receiver = try await Self.makeReceiver(connectivity: capabilities.connectivity)
      if Task.isCancelled {
        receiver.close()
        return .cancelled
      }
      install(receiver)
      let lost = AsyncStream<Void>.makeStream()
      receiver.onConnectionChanged = { transport in
        Self.log.info("transport \(transport, privacy: .public)")
        if ["failed", "disconnected", "closed"].contains(transport) { lost.continuation.yield() }
      }
      let offer = try await receiver.makeDescription(offer: true).sdp
      try Task.checkCancellation()
      var start = request(restart ? .restart : .start, offer: offer)
      tunnel = await openTunnel?()
      if let tunnel {
        start.tunnelMedia = .init(endpointId: tunnel.endpointId, flowId: Int(tunnel.flowId))
      }
      let reply = try await client.screenSharing(start)
      Self.log.info(
        "start \(reply.status, privacy: .public) tunnel=\(tunnel != nil) hostTunnel=\(reply.tunnelMedia != nil)")
      try Task.checkCancellation()
      if reply.status == "starting" { return .lost }
      guard reply.version == 1, reply.status == "connecting", var answer = reply.answer else {
        return .ended(reply.message ?? "The simulator's Mac can't stream it right now.")
      }
      if let tunnel, reply.tunnelMedia?.flowId == Int(tunnel.flowId),
        let address = ScreenSharingTunnelSDP.localIPv4(inOffer: offer)
      {
        answer = ScreenSharingTunnelSDP.answer(answer, routedTo: address, port: tunnel.localPort)
      }
      try await receiver.accept(.init(kind: "answer", sdp: answer))
      return await heartbeat(until: lost.stream)
    } catch {
      if error is CancellationError || Task.isCancelled { return .cancelled }
      Self.log.error("attempt failed: \(String(describing: error), privacy: .public)")
      return .ended(Self.message(for: error))
    }
  }

  /// Heartbeats every 8 s until the transport drops or the host ends the stream.
  private func heartbeat(until lost: AsyncStream<Void>) async -> Outcome {
    let outcomes = AsyncStream<Outcome>.makeStream()
    let beats = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(8))
        guard let self, !Task.isCancelled else { return }
        if self.phase != .streaming, let stats = await self.receiver?.statistics() {
          let keys = [
            "mimeType", "decoderImplementation", "packetsReceived", "framesReceived", "framesDecoded",
            "keyFramesDecoded", "framesDropped", "pliCount", "bytesReceived",
          ]
          let summary = keys.compactMap { key in stats.first { $0.key.hasSuffix(key) }.map { "\(key)=\($0.value)" } }
          let failure = self.receiver?.failure ?? "none"
          Self.log.info(
            "no frame yet: \(summary.joined(separator: " "), privacy: .public) decoder=\(failure, privacy: .public)")
        }
        do {
          let reply = try await self.client.screenSharing(self.request(.heartbeat))
          if !["connecting", "viewing"].contains(reply.status) {
            outcomes.continuation.yield(.ended(reply.message ?? "The simulator stopped streaming."))
            return
          }
        } catch {
          if !Task.isCancelled { outcomes.continuation.yield(.lost) }
          return
        }
      }
    }
    let watcher = Task {
      for await _ in lost {
        outcomes.continuation.yield(.lost)
        return
      }
    }
    defer {
      beats.cancel()
      watcher.cancel()
    }
    return await withTaskCancellationHandler {
      for await outcome in outcomes.stream { return outcome }
      return .cancelled
    } onCancel: {
      outcomes.continuation.finish()
    }
  }

  private func install(_ receiver: ScreenSharingReceiver) {
    self.receiver = receiver
    receiver.simulatorChannel.onMessage = { [weak self] message in
      guard case .state(let state) = message else { return }
      self?.state = state
    }
  }

  private func closeReceiver() {
    receiver?.onConnectionChanged = nil
    receiver?.simulatorChannel.onMessage = nil
    receiver?.close()
    receiver = nil
  }

  private func request(
    _ operation: ServerScreenSharingRequest.Operation, offer: String? = nil
  ) -> ServerScreenSharingRequest {
    .init(
      operation: operation, workspaceId: workspaceId, paneId: paneId, viewerId: viewerId,
      displayId: target, offer: offer)
  }

  /// The product receiver: field trials installed (or proven installed) before the peer exists.
  private static func makeReceiver(
    connectivity: ServerScreenSharingConnectivity?
  ) async throws
    -> ScreenSharingReceiver
  {
    try ScreenSharingFieldTrials.process.install(profile: try ScreenSharingDiagnosticProfile.process())
    let ice = try connectivity.map { connectivity in
      try ScreenSharingICEConfiguration(
        servers: connectivity.servers.map {
          try ScreenSharingICEServer(urls: $0.urls, username: $0.username, credential: $0.credential)
        },
        relayOnly: connectivity.relayOnly)
    }
    return try await ScreenSharingReceiver(configuration: .init(), metrics: ScreenSharingMetrics(), connectivity: ice)
  }

  private static func message(for error: any Error) -> String {
    if case CodevisorServerClientError.httpStatus(_, let body) = error,
      let data = body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = object["error"] as? String
    {
      return message
    }
    return error.localizedDescription
  }
}
