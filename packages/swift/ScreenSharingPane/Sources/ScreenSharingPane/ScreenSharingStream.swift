import CodevisorClient
import CodevisorCloud
import CodevisorCore
import Foundation
import Observation
import OSLog
import ScreenSharing
import ScreenSharingV2
import ScreenSharingWebRTC

struct ScreenSharingStreamSponsor {
  typealias MakeWebRTC = @MainActor (ServerScreenSharingConnectivity?) async throws -> any ScreenSharingOfferingSession

  let workspaceId: UUID
  let paneId: UUID
  let client: any CodevisorServerClienting
  let openTunnel: (@MainActor () async -> CloudTunnelMediaRoute?)?
  var v2: ScreenSharingV2Connector?
  var makeWebRTC: MakeWebRTC = { try await ScreenSharingStream.makeReceiver(connectivity: $0) }
  var clock: any Clock<Duration> = ContinuousClock()
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
  private(set) var session: (any ScreenSharingViewingSession)?
  private(set) var control: ScreenSharingControlSession?
  private(set) var diagnostics = ScreenSharingViewerDiagnostics()

  @ObservationIgnored let displayId: String
  @ObservationIgnored private let sponsor: ScreenSharingStreamSponsor
  @ObservationIgnored private let viewerId = UUID()
  @ObservationIgnored private var runner: Task<Void, Never>?
  @ObservationIgnored private var statistics: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var v2Failed = false
  @ObservationIgnored private var presented = false
  private static let log = Logger(subsystem: "com.codevisor.ScreenSharingPane", category: "Stream")
  static let heartbeatInterval: Duration = .seconds(8)
  static let missingVideoTimeout: Duration = .seconds(24)

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
    closeSession()
    guard started else { return }
    started = false
    let request = request(.stop)
    let client = sponsor.client
    Task { _ = try? await client.screenSharing(request) }
  }

  func presentedFirstFrame() {
    presented = true
    guard phase != .streaming else { return }
    Self.log.info("first frame")
    phase = .streaming
  }

  private func run() async {
    var restarts = 0
    var fresh = false
    while !Task.isCancelled {
      let outcome = await attempt(restart: restarts > 0 && !fresh)
      fresh = false
      closeSession()
      switch outcome {
      case .cancelled:
        return
      case .ended(let message):
        phase = .failed(message)
        runner = nil
        return
      case .fallback:
        Self.log.info("engine v2 ended before video; using WebRTC")
        v2Failed = true
        fresh = true
      case .lost:
        guard restarts < 12 else {
          phase = .failed("The connection to the Mac keeps dropping.")
          runner = nil
          return
        }
        restarts += 1
        phase = .reconnecting
        try? await sponsor.clock.sleep(for: .seconds(min(6, restarts)))
      }
    }
  }

  private enum Outcome { case cancelled, lost, ended(String), fallback }

  private func attempt(restart: Bool) async -> Outcome {
    presented = false
    do {
      let capabilities = try await sponsor.client.screenSharing(request(.capabilities))
      try Task.checkCancellation()
      guard capabilities.version == 1, ["available", "busy"].contains(capabilities.status) else {
        return .ended(capabilities.message ?? "This Mac can't share its screen right now.")
      }
      if let v2 = sponsor.v2, !v2Failed, capabilities.engines?.contains(ScreenSharingEngine.v2.rawValue) == true {
        let outcome = await outcome { try await attemptV2(v2, restart: restart) }
        switch outcome {
        case .lost, .ended: return presented ? outcome : .fallback
        case .cancelled, .fallback: return outcome
        }
      }
      return try await attemptWebRTC(connectivity: capabilities.connectivity, restart: restart)
    } catch {
      return Self.outcome(of: error)
    }
  }

  private func outcome(_ body: () async throws -> Outcome) async -> Outcome {
    do {
      return try await body()
    } catch {
      return Self.outcome(of: error)
    }
  }

  private static func outcome(of error: any Error) -> Outcome {
    if error is CancellationError || Task.isCancelled { return .cancelled }
    log.error("attempt failed: \(String(describing: error), privacy: .public)")
    return .ended(message(for: error))
  }

  private func attemptV2(_ v2: ScreenSharingV2Connector, restart: Bool) async throws -> Outcome {
    guard let address = await v2.address() else { return .fallback }
    try Task.checkCancellation()
    var start = request(restart ? .restart : .start)
    start.engine = ScreenSharingEngine.v2.rawValue
    start.media = address
    start.chroma = await v2.chroma().rawValue
    started = true
    let reply = try await sponsor.client.screenSharing(start)
    try Task.checkCancellation()
    guard reply.version == 1, reply.status == "connecting", let grant = reply.media else { return .fallback }
    let session: any ScreenSharingV2StartableSession
    do {
      session = try await v2.connect(grant)
    } catch {
      return Task.isCancelled ? .cancelled : .fallback
    }
    let lost = install(session)
    do {
      try await session.start(token: grant.token)
    } catch {
      return Task.isCancelled ? .cancelled : .fallback
    }
    return await heartbeat(until: lost, missingVideo: Self.missingVideoTimeout)
  }

  private func attemptWebRTC(connectivity: ServerScreenSharingConnectivity?, restart: Bool) async throws -> Outcome {
    var tunnel: CloudTunnelMediaRoute?
    defer { tunnel?.close() }
    let session = try await sponsor.makeWebRTC(connectivity)
    if Task.isCancelled {
      session.close()
      return .cancelled
    }
    let lost = install(session)
    let offer = try await session.offer()
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
    try await session.accept(answer)
    return await heartbeat(until: lost)
  }

  private func heartbeat(until lost: AsyncStream<Void>, missingVideo: Duration? = nil) async -> Outcome {
    let outcomes = AsyncStream<Outcome>.makeStream()
    let clock = sponsor.clock
    let beats = Task { @MainActor [weak self] in
      var waited = Duration.zero
      while !Task.isCancelled {
        try? await clock.sleep(for: Self.heartbeatInterval)
        guard let self, !Task.isCancelled else { return }
        let reply: ServerScreenSharingReply
        do {
          reply = try await self.sponsor.client.screenSharing(self.request(.heartbeat))
        } catch {
          if !Task.isCancelled { outcomes.continuation.yield(.lost) }
          return
        }
        guard ["connecting", "viewing"].contains(reply.status) else {
          outcomes.continuation.yield(.ended(reply.message ?? "The Mac stopped sharing its screen."))
          return
        }
        guard let missingVideo, !self.presented, reply.message == nil else { continue }
        waited += Self.heartbeatInterval
        if waited >= missingVideo {
          outcomes.continuation.yield(.fallback)
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

  private func install(_ session: any ScreenSharingViewingSession) -> AsyncStream<Void> {
    self.session = session
    diagnostics = ScreenSharingViewerDiagnostics()
    control = session.control.map { ScreenSharingControlSession(channel: $0, clock: ContinuousClock()) }
    let lost = AsyncStream<Void>.makeStream()
    session.onConnectionChanged = { transport in
      Self.log.info("transport \(transport, privacy: .public)")
      if ["failed", "disconnected", "closed"].contains(transport) { lost.continuation.yield() }
    }
    let clock = sponsor.clock
    statistics = Task { [weak self, weak session] in
      while !Task.isCancelled {
        guard (try? await clock.sleep(for: .seconds(1))) != nil, let self, let session else { return }
        guard self.presented else { continue }
        let statistics = await session.statistics()
        guard !Task.isCancelled else { return }
        self.diagnostics.update(
          metrics: session.metrics.snapshot(), statistics: statistics, now: ProcessInfo.processInfo.systemUptime)
      }
    }
    return lost.stream
  }

  private func closeSession() {
    statistics?.cancel()
    statistics = nil
    control?.close()
    control = nil
    session?.onConnectionChanged = nil
    session?.close()
    session = nil
  }

  private func request(
    _ operation: ServerScreenSharingRequest.Operation, offer: String? = nil
  ) -> ServerScreenSharingRequest {
    .init(
      operation: operation, workspaceId: sponsor.workspaceId, paneId: sponsor.paneId, viewerId: viewerId,
      displayId: displayId, offer: offer)
  }

  static func makeReceiver(connectivity: ServerScreenSharingConnectivity?) async throws -> ScreenSharingReceiver {
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
