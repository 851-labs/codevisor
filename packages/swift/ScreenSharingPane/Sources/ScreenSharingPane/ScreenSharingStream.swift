import CodevisorClient
import CodevisorCore
import Foundation
import Observation
import OSLog
import ScreenSharing
import ScreenSharingV2

struct ScreenSharingStreamSponsor {
  let workspaceId: UUID
  let paneId: UUID
  let client: any CodevisorServerClienting
  var v2: ScreenSharingV2Connector
  var clock: any Clock<Duration> = ContinuousClock()
  var now: @Sendable () -> ContinuousClock.Instant = { .now }
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
  private(set) var connectStep: ScreenSharingConnectStage?

  @ObservationIgnored let displayId: String
  @ObservationIgnored private let sponsor: ScreenSharingStreamSponsor
  @ObservationIgnored private let viewerId = UUID()
  @ObservationIgnored private var runner: Task<Void, Never>?
  @ObservationIgnored private var statistics: Task<Void, Never>?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var presented = false
  @ObservationIgnored private var times = ScreenSharingConnectTimes(at: .now)
  @ObservationIgnored private var reportsProgress = false
  @ObservationIgnored private var hostNotice: String?
  @ObservationIgnored private var settle: (id: UUID, resume: (Outcome) -> Void)?
  private static let log = Logger(subsystem: "com.codevisor.ScreenSharingPane", category: "Stream")
  static let heartbeatInterval: Duration = .seconds(8)
  static let v2Unavailable =
    "This Mac needs a newer version of Codevisor to share its screen. Update Codevisor on it, then retry."

  init(displayId: String, sponsor: ScreenSharingStreamSponsor) {
    self.displayId = displayId
    self.sponsor = sponsor
  }

  func start(since began: ContinuousClock.Instant? = nil, capabilities: ServerScreenSharingReply? = nil) {
    guard runner == nil else { return }
    phase = .connecting
    let began = began ?? sponsor.now()
    runner = Task { [weak self] in await self?.run(since: began, capabilities: capabilities) }
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
    connectStep = nil
    guard phase != .streaming else { return }
    let summary = times.summary(at: sponsor.now())
    session?.metrics.label("connectTime", summary)
    Self.log.notice("first frame in \(summary, privacy: .public)")
    phase = .streaming
  }

  private func run(since began: ContinuousClock.Instant, capabilities: ServerScreenSharingReply?) async {
    var restarts = 0
    var began = began
    var capabilities = capabilities
    while !Task.isCancelled {
      let outcome = await attempt(restart: restarts > 0, since: began, capabilities: capabilities)
      capabilities = nil
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
          phase = .failed("The connection to the Mac keeps dropping.")
          runner = nil
          return
        }
        restarts += 1
        phase = .reconnecting
        try? await sponsor.clock.sleep(for: .seconds(min(6, restarts)))
        began = sponsor.now()
      }
    }
  }

  private enum Outcome { case cancelled, lost, ended(String) }

  private func attempt(
    restart: Bool, since began: ContinuousClock.Instant, capabilities: ServerScreenSharingReply?
  ) async -> Outcome {
    presented = false
    hostNotice = nil
    reportsProgress = false
    connectStep = nil
    times = ScreenSharingConnectTimes(at: began)
    let id = UUID()
    let body = Task { @MainActor [weak self] () -> Outcome in
      await self?.attemptBody(restart: restart, capabilities: capabilities, attempt: id) ?? .cancelled
    }
    let deadline = Task { @MainActor [weak self] in
      await self?.expire(since: began, restart: restart, attempt: id, body: body)
    }
    defer { deadline.cancel() }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        settle = (id, { continuation.resume(returning: $0) })
        Task { @MainActor [weak self] in self?.finish(await body.value, attempt: id) }
      }
    } onCancel: {
      body.cancel()
      Task { @MainActor [weak self] in self?.finish(.cancelled, attempt: id) }
    }
  }

  private func finish(_ outcome: Outcome, attempt id: UUID) {
    guard let settle, settle.id == id else { return }
    self.settle = nil
    settle.resume(outcome)
  }

  private func enter(_ stage: ScreenSharingConnectStage) {
    guard stage != times.stage else { return }
    times.enter(stage, at: sponsor.now())
    if reportsProgress, !presented { connectStep = stage }
  }

  private func expire(
    since began: ContinuousClock.Instant, restart: Bool, attempt id: UUID, body: Task<Outcome, Never>
  ) async {
    let clock = sponsor.clock
    do {
      try await clock.sleep(for: max(.zero, ScreenSharingConnectStage.stillConnectingAfter - (sponsor.now() - began)))
      guard !presented, settle?.id == id else { return }
      reportsProgress = true
      connectStep = times.stage
      try await sleepUntilDeadline(since: began)
      while hostNotice != nil, !presented {
        while hostNotice != nil, !presented { try await clock.sleep(for: Self.heartbeatInterval) }
        try await sleepUntilDeadline(since: sponsor.now())
      }
    } catch { return }
    guard !presented, settle?.id == id else { return }
    let stage = times.stage
    Self.log.error(
      "gave up at \(stage.rawValue, privacy: .public) after \(self.times.summary(at: self.sponsor.now()), privacy: .public)"
    )
    body.cancel()
    closeSession()
    finish(restart ? .lost : .ended(stage.failure), attempt: id)
  }

  private func sleepUntilDeadline(since began: ContinuousClock.Instant) async throws {
    try await sponsor.clock.sleep(for: max(.zero, ScreenSharingConnectStage.deadline - (sponsor.now() - began)))
    guard sponsor.client.isReconnecting else { return }
    try await sponsor.clock.sleep(for: ScreenSharingConnectStage.reconnectingTunnelGrace)
  }

  private func attemptBody(
    restart: Bool, capabilities discovered: ServerScreenSharingReply?, attempt id: UUID
  ) async -> Outcome {
    do {
      let capabilities: ServerScreenSharingReply
      if let discovered {
        capabilities = discovered
      } else {
        capabilities = try await send(request(.capabilities))
      }
      try Task.checkCancellation()
      guard capabilities.version == 1, ["available", "busy"].contains(capabilities.status) else {
        return .ended(capabilities.message ?? "This Mac can't share its screen right now.")
      }
      guard capabilities.engines?.contains(ScreenSharingEngine.v2.rawValue) == true else {
        return .ended(Self.v2Unavailable)
      }
      let outcome = try await attemptV2(sponsor.v2, restart: restart, attempt: id)
      if case .lost = outcome, !presented, !restart { return .ended(times.stage.failure) }
      return outcome
    } catch {
      return Self.outcome(of: error)
    }
  }

  private static func outcome(of error: any Error) -> Outcome {
    if error is CancellationError || Task.isCancelled { return .cancelled }
    log.error("attempt failed: \(String(describing: error), privacy: .public)")
    return .ended(message(for: error))
  }

  private func attemptV2(_ v2: ScreenSharingV2Connector, restart: Bool, attempt id: UUID) async throws -> Outcome {
    enter(.connectingMedia)
    guard let address = await v2.address() else { return .lost }
    try Task.checkCancellation()
    var start = request(restart ? .restart : .start)
    start.engine = ScreenSharingEngine.v2.rawValue
    start.media = address
    start.chroma = await v2.chroma().rawValue
    started = true
    enter(.startingHost)
    Self.log.notice("starting: \(self.times.summary(at: self.sponsor.now()), privacy: .public)")
    let reply = try await send(start)
    try Task.checkCancellation()
    guard reply.version == 1, reply.status == "connecting", let grant = reply.media else {
      return .ended(reply.message ?? "This Mac can't share its screen right now.")
    }
    enter(.connectingMedia)
    let session: any ScreenSharingV2StartableSession
    do {
      session = try await v2.connect(grant)
    } catch {
      return Task.isCancelled ? .cancelled : .lost
    }
    guard !Task.isCancelled, settle?.id == id else {
      session.close()
      return .cancelled
    }
    enter(.handshake)
    let lost = install(session)
    do {
      try await session.start(token: grant.token)
    } catch {
      return Task.isCancelled ? .cancelled : .lost
    }
    if !presented { enter(.waitingForVideo) }
    Self.log.notice("media session up: \(self.times.summary(at: self.sponsor.now()), privacy: .public)")
    hostNotice = reply.message
    return await heartbeat(until: lost)
  }

  private func send(_ request: ServerScreenSharingRequest) async throws -> ServerScreenSharingReply {
    let clock = sponsor.clock
    return try await ServerConnectionLoss.retryingInterruptions(sleep: { try await clock.sleep(for: $0) }) {
      try await sponsor.client.screenSharing(request)
    }
  }

  private func heartbeat(until lost: AsyncStream<Void>) async -> Outcome {
    let outcomes = AsyncStream<Outcome>.makeStream()
    let clock = sponsor.clock
    let beats = Task { @MainActor [weak self] in
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
        self.hostNotice = reply.message
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
          metrics: session.metrics.snapshot(), timeline: session.metrics.timeline, statistics: statistics,
          now: ProcessInfo.processInfo.systemUptime)
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

  private func request(_ operation: ServerScreenSharingRequest.Operation) -> ServerScreenSharingRequest {
    .init(
      operation: operation, workspaceId: sponsor.workspaceId, paneId: sponsor.paneId, viewerId: viewerId,
      displayId: displayId)
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
