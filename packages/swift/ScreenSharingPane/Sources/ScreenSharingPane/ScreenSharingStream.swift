import CodevisorClient
import CodevisorCloud
import Foundation
import Observation
import OSLog
import ScreenSharing
import ScreenSharingWebRTC

struct ScreenSharingStreamSponsor {
  let workspaceId: UUID
  let paneId: UUID
  let client: any CodevisorServerClienting
  let openTunnel: (@MainActor () async -> CloudTunnelMediaRoute?)?
}

@MainActor
@Observable
final class ScreenSharingStream {
  enum Phase: Equatable {
    case connecting
    case streaming
    case reconnecting
    case failed(String)
  }

  private(set) var phase: Phase = .connecting
  private(set) var receiver: ScreenSharingReceiver?
  private(set) var control: ScreenSharingControlSession?

  @ObservationIgnored let displayId: String
  @ObservationIgnored private let sponsor: ScreenSharingStreamSponsor
  @ObservationIgnored private let viewerId = UUID()
  @ObservationIgnored private var runner: Task<Void, Never>?
  @ObservationIgnored private var started = false
  private static let log = Logger(subsystem: "com.codevisor.ScreenSharingPane", category: "Stream")

  init(displayId: String, sponsor: ScreenSharingStreamSponsor) {
    self.displayId = displayId
    self.sponsor = sponsor
  }

  func start() {
    guard runner == nil else { return }
    phase = .connecting
    runner = Task { [weak self] in await self?.run() }
  }

  func stop() {
    runner?.cancel()
    runner = nil
    closeReceiver()
    guard started else { return }
    started = false
    let request = request(.stop)
    let client = sponsor.client
    Task { _ = try? await client.screenSharing(request) }
  }

  func presentedFirstFrame() {
    guard phase != .streaming else { return }
    Self.log.info("first frame")
    phase = .streaming
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
          phase = .failed("The connection to the Mac keeps dropping.")
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
      let capabilities = try await sponsor.client.screenSharing(request(.capabilities))
      try Task.checkCancellation()
      guard capabilities.version == 1, ["available", "busy"].contains(capabilities.status) else {
        return .ended(capabilities.message ?? "This Mac can't share its screen right now.")
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
      tunnel = await sponsor.openTunnel?()
      if let tunnel { start.tunnelMedia = .init(endpointId: tunnel.endpointId, flowId: Int(tunnel.flowId)) }
      started = true
      let reply = try await sponsor.client.screenSharing(start)
      try Task.checkCancellation()
      guard reply.version == 1, reply.status == "connecting", var answer = reply.answer else {
        return .ended(reply.message ?? "This Mac can't share its screen right now.")
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

  private func heartbeat(until lost: AsyncStream<Void>) async -> Outcome {
    let outcomes = AsyncStream<Outcome>.makeStream()
    let beats = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(8))
        guard let self, !Task.isCancelled else { return }
        do {
          let reply = try await self.sponsor.client.screenSharing(self.request(.heartbeat))
          if !["connecting", "viewing"].contains(reply.status) {
            outcomes.continuation.yield(.ended(reply.message ?? "The Mac stopped sharing its screen."))
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
    control = receiver.control.map { ScreenSharingControlSession(channel: $0, clock: ContinuousClock()) }
  }

  private func closeReceiver() {
    control?.close()
    control = nil
    receiver?.onConnectionChanged = nil
    receiver?.close()
    receiver = nil
  }

  private func request(
    _ operation: ServerScreenSharingRequest.Operation, offer: String? = nil
  ) -> ServerScreenSharingRequest {
    .init(
      operation: operation, workspaceId: sponsor.workspaceId, paneId: sponsor.paneId, viewerId: viewerId,
      displayId: displayId, offer: offer)
  }

  private static func makeReceiver(
    connectivity: ServerScreenSharingConnectivity?
  ) async throws
    -> ScreenSharingReceiver
  {
    ScreenSharingFieldTrials.process.installProduct()
    let ice = try connectivity.map { connectivity in
      try ScreenSharingICEConfiguration(
        servers: connectivity.servers.map {
          try ScreenSharingICEServer(urls: $0.urls, username: $0.username, credential: $0.credential)
        },
        relayOnly: connectivity.relayOnly)
    }
    return try await ScreenSharingReceiver(configuration: .init(), metrics: ScreenSharingMetrics(), connectivity: ice)
  }

  static func message(for error: any Error) -> String {
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
