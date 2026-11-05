import CodevisorClient
import CodevisorCloud
import CodevisorCore
import Foundation
import Observation
import OSLog
import ScreenSharing
import ScreenSharingWebRTC

@MainActor
@Observable
public final class SimulatorStreamConnection: SimulatorSharedConnection {
  public private(set) var phase: SimulatorConnectionPhase = .connecting
  public private(set) var state: ScreenSharingSimulatorState?
  public private(set) var frameSize: CGSize?

  @ObservationIgnored let udid: String
  @ObservationIgnored private var sponsor: SimulatorStreamSponsor
  @ObservationIgnored private let viewerId = UUID()
  @ObservationIgnored private var runner: Task<Void, Never>?
  private var session: (any ScreenSharingViewingSession)?
  @ObservationIgnored private var simulator: (any ScreenSharingMessageChannel<ScreenSharingSimulatorMessage>)?
  private static let log = Logger(subsystem: "com.codevisor.SimulatorPane", category: "Stream")

  private var client: any CodevisorServerClienting { sponsor.client }

  init(udid: String, sponsor: SimulatorStreamSponsor) {
    self.udid = udid
    self.sponsor = sponsor
  }

  var target: String { "simulator:\(udid)" }

  public var source: SimulatorScreenSource? { session.map { .video($0.frames, $0.metrics) } }

  public func start() {
    guard runner == nil else { return }
    phase = .connecting
    runner = Task { [weak self] in await self?.run() }
  }

  public func stop() {
    runner?.cancel()
    runner = nil
    closeSession()
    let request = request(.stop)
    let client = client
    Task { _ = try? await client.screenSharing(request) }
  }

  func rebind(to sponsor: SimulatorStreamSponsor) {
    Self.log.info("rebinding to another pane")
    stop()
    self.sponsor = sponsor
    start()
  }

  @discardableResult
  public func send(_ message: ScreenSharingSimulatorMessage) -> Bool {
    guard let simulator, simulator.isAvailable else { return false }
    return simulator.send(message)
  }

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
      closeSession()
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
    do {
      let capabilities = try await client.screenSharing(request(.capabilities))
      try Task.checkCancellation()
      Self.log.info("capabilities \(capabilities.status, privacy: .public)")
      if capabilities.status == "starting" { return .lost }
      guard capabilities.version == 1, capabilities.status == "available" else {
        return .ended(capabilities.message ?? "This simulator isn't available on its Mac.")
      }
      guard let v2 = sponsor.v2 else { return try await attemptWebRTC(capabilities, restart: restart) }
      guard capabilities.engines?.contains(ScreenSharingEngine.v2.rawValue) == true else {
        return .ended("Update Codevisor on the simulator's Mac to stream it here.")
      }

      return try await attemptV2(v2, restart: restart)
    } catch {
      if error is CancellationError || Task.isCancelled { return .cancelled }
      Self.log.error("attempt failed: \(String(describing: error), privacy: .public)")
      return .ended(Self.message(for: error))
    }
  }

  private func attemptV2(_ v2: SimulatorStreamV2, restart: Bool) async throws -> Outcome {
    guard let address = await v2.address() else {
      Self.log.error("v2 endpoint unavailable")
      return .lost
    }
    try Task.checkCancellation()
    var start = request(restart ? .restart : .start)
    start.engine = ScreenSharingEngine.v2.rawValue
    start.media = address
    let reply = try await client.screenSharing(start)
    Self.log.info("start v2 \(reply.status, privacy: .public)")
    try Task.checkCancellation()
    if reply.status == "starting" { return .lost }
    guard reply.version == 1, reply.status == "connecting", let grant = reply.media else {
      return .ended(reply.message ?? "The simulator's Mac can't stream it right now.")
    }
    let session: any ScreenSharingSimulatorSession
    do {
      session = try await v2.connect(grant)
    } catch {
      if Task.isCancelled { return .cancelled }
      Self.log.error("v2 connect failed: \(String(describing: error), privacy: .public)")
      return .lost
    }
    if Task.isCancelled {
      session.close()
      return .cancelled
    }
    let lost = install(session, simulator: session.simulator)
    do {
      try await session.start(token: grant.token)
    } catch {
      if Task.isCancelled { return .cancelled }
      Self.log.error("v2 start failed: \(String(describing: error), privacy: .public)")
      return .lost
    }
    return await heartbeat(until: lost)
  }

  private func attemptWebRTC(_ capabilities: ServerScreenSharingReply, restart: Bool) async throws -> Outcome {
    var tunnel: CloudTunnelMediaRoute?
    defer { tunnel?.close() }
    let receiver = try await Self.makeReceiver(connectivity: capabilities.connectivity)
    if Task.isCancelled {
      receiver.close()
      return .cancelled
    }
    let lost = install(receiver, simulator: receiver.simulatorChannel)
    let offer = try await receiver.makeDescription(offer: true).sdp
    try Task.checkCancellation()
    var start = request(restart ? .restart : .start, offer: offer)
    tunnel = await sponsor.openTunnel?()
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
    return await heartbeat(until: lost)
  }

  private func heartbeat(until lost: AsyncStream<Void>) async -> Outcome {
    let outcomes = AsyncStream<Outcome>.makeStream()
    let beats = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(8))
        guard let self, !Task.isCancelled else { return }
        if self.phase != .streaming, let stats = await self.session?.statistics() {
          let keys = [
            "mimeType", "decoderImplementation", "packetsReceived", "framesReceived", "framesDecoded",
            "keyFramesDecoded", "framesDropped", "pliCount", "bytesReceived",
          ]
          let summary = keys.compactMap { key in stats.first { $0.key.hasSuffix(key) }.map { "\(key)=\($0.value)" } }
          let failure = self.session?.failure ?? "none"
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

  private func install(
    _ session: any ScreenSharingViewingSession,
    simulator: any ScreenSharingMessageChannel<ScreenSharingSimulatorMessage>
  ) -> AsyncStream<Void> {
    self.session = session
    self.simulator = simulator
    simulator.onMessage = { [weak self] message in
      guard case .state(let state) = message else { return }
      self?.state = state
    }
    let lost = AsyncStream<Void>.makeStream()
    session.onConnectionChanged = { transport in
      Self.log.info("transport \(transport, privacy: .public)")
      if ["failed", "disconnected", "closed"].contains(transport) { lost.continuation.yield() }
    }
    return lost.stream
  }

  private func closeSession() {
    session?.onConnectionChanged = nil
    simulator?.onMessage = nil
    session?.close()
    session = nil
    simulator = nil
  }

  private func request(
    _ operation: ServerScreenSharingRequest.Operation, offer: String? = nil
  ) -> ServerScreenSharingRequest {
    .init(
      operation: operation, workspaceId: sponsor.workspaceId, paneId: sponsor.paneId, viewerId: viewerId,
      displayId: target, offer: offer)
  }

  private static func makeReceiver(
    connectivity: ServerScreenSharingConnectivity?
  ) async throws
    -> ScreenSharingReceiver
  {
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
