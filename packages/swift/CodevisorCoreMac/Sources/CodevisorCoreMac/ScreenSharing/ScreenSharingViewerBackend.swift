import CodevisorClient
import CodevisorCore
import ScreenSharing
import ScreenSharingV2
import ComposableArchitecture
import Foundation
import OSLog

@CasePathable
public enum ScreenSharingViewerEvent: Equatable, Sendable {
  case elsewhere(ScreenSharingViewerEndpoint?)
  case ended(String)
  case opened(ScreenSharingViewerEndpoint)
  case ready
  case reconnecting
  case hostNotice(String?)
  case progress(ScreenSharingConnectStage)
}

@DependencyClient
public struct ScreenSharingViewerBackend: Sendable {
  public var connect: @Sendable (_ displayId: String) async -> AsyncStream<ScreenSharingViewerEvent> = { _ in
    .finished
  }
  public var switchDisplay: @Sendable (_ displayId: String) async -> AsyncStream<ScreenSharingViewerEvent> = { _ in
    .finished
  }
  public var discover: @Sendable () async throws -> [ServerScreenSharingDisplay]
  public var claim: @Sendable () async -> Void = {}
  public var setVisible: @Sendable (_ visible: Bool) async -> Void = { _ in }
  public var retire: @Sendable () async -> Void = {}
  public var liveStreams: @Sendable () async -> AsyncStream<Void> = { .finished }
}

extension ScreenSharingViewerBackend: TestDependencyKey {
  public static var testValue: Self { Self() }
}

extension ScreenSharingViewerBackend {
  @MainActor
  public static func native(
    client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID, machineId: String? = nil,
    role: ScreenSharingViewerRole = .tab
  ) -> Self {
    native(
      client: client, workspaceId: workspaceId, paneId: paneId, machineId: machineId, role: role,
      v2: ScreenSharingViewerMedia.connector,
      sleep: { try await Task.sleep(for: $0) },
      makeSurface: { session in
        try ScreenSharingVideoSurface(mailbox: session.frames, metrics: session.metrics)
      },
      vncOpen: { displayId in
        let socket = try client.screenSharingVNCSocket(displayId: displayId)
        return try await VNCConnection.open(transport: RFBWebSocketTransport(socket: socket), password: nil)
      })
  }

  typealias NativeVNCOpen = @Sendable (String) async throws -> (client: RFBClient, outcome: RFBHandshake.Outcome)

  @MainActor
  static func native(
    client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID, machineId: String? = nil,
    role: ScreenSharingViewerRole = .tab,
    v2: ScreenSharingV2Connector,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface,
    vncOpen: @escaping NativeVNCOpen = { _ in throw RFBError.transport("This machine has no VNC display.") },
    target: String? = nil,
    heartbeatInterval: Duration = .seconds(8)
  ) -> Self {
    let sharesStream = machineId != nil
    let runner = NativeScreenSharingViewerRunner(
      client: client, workspaceId: workspaceId, paneId: paneId, sleep: sleep, now: now,
      makeSurface: makeSurface, vncOpen: vncOpen, target: target, v2: v2,
      heartbeatInterval: heartbeatInterval, sound: !sharesStream)
    guard let machineId else {
      return Self(
        connect: { display in await runner.connect(display) },
        switchDisplay: { display in await runner.connect(display) }, discover: { try await runner.discover() },
        claim: {}, setVisible: { _ in }, retire: {}, liveStreams: { .finished })
    }
    let share = ScreenSharingViewerRegistry.shared.share(
      machineId: machineId, paneId: paneId, role: role, runner: runner)
    return Self(
      connect: { display in await share.connect(display) },
      switchDisplay: { display in await share.connect(display, switching: true) },
      discover: { try await runner.discover() },
      claim: { await share.claim() }, setVisible: { visible in await share.setVisible(visible) },
      retire: { await share.retire() }, liveStreams: { await share.liveStreams() })
  }
}

@MainActor
private final class NativeScreenSharingViewerRunner: ScreenSharingViewerConnecting {
  private typealias Outcome = ScreenSharingViewerAttempt.Outcome
  private let client: any CodevisorServerClienting
  private let workspaceId: UUID
  private let paneId: UUID
  private let sleep: @Sendable (Duration) async throws -> Void
  private let now: @Sendable () -> ContinuousClock.Instant
  private let makeSurface: @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface
  private let vncOpen: ScreenSharingViewerBackend.NativeVNCOpen
  private var previous: Task<Void, Never>?
  private var provider: String?
  private var controlLease = false
  private var discovered: (began: ContinuousClock.Instant, reply: ServerScreenSharingReply)?
  private var vncRunners: [String: VNCScreenSharingViewerRunner] = [:]
  private let target: String?
  private let heartbeatInterval: Duration
  private let v2: ScreenSharingV2Connector
  private let sound: Bool

  init(
    client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface,
    vncOpen: @escaping ScreenSharingViewerBackend.NativeVNCOpen,
    target: String? = nil,
    v2: ScreenSharingV2Connector,
    heartbeatInterval: Duration = .seconds(8),
    sound: Bool = true
  ) {
    self.sound = sound
    self.v2 = v2
    self.target = target
    self.heartbeatInterval = heartbeatInterval
    self.client = client
    self.workspaceId = workspaceId
    self.paneId = paneId
    self.sleep = sleep
    self.now = now
    self.makeSurface = makeSurface
    self.vncOpen = vncOpen
  }

  func discover() async throws -> [ServerScreenSharingDisplay] {
    await previous?.value
    try Task.checkCancellation()
    let began = now()
    let capabilities = request(.capabilities, viewerId: UUID())
    let client = client
    let sleep = sleep
    let reply = try await withinDeadline(since: began, failure: ScreenSharingConnectStage.reachingHost.failure) {
      return try await ScreenSharingTransientRetry.run(sleep: sleep) { try await client.screenSharing(capabilities) }
    }
    guard reply.version == 1, ["available", "busy"].contains(reply.status) else {
      throw ViewerError(reply.message ?? "Screen Sharing is unavailable on this Mac.")
    }
    provider = reply.provider
    controlLease = reply.controlLease == true
    discovered = (began, reply)
    return reply.displays
  }

  func idle() async { await previous?.value }

  func connect(_ display: String) -> AsyncStream<ScreenSharingViewerEvent> {
    if provider == "vnc" || display.hasPrefix("vnc:") { return vncRunner(for: display).connect() }
    return AsyncStream { continuation in
      let pending = previous
      let run = Task { @MainActor [self] in
        await pending?.value
        if !Task.isCancelled {
          await self.run(display: display) { continuation.yield($0) }
        }
        continuation.finish()
      }
      previous = run
      continuation.onTermination = { _ in run.cancel() }
    }
  }

  private func vncRunner(for display: String) -> VNCScreenSharingViewerRunner {
    if let runner = vncRunners[display] { return runner }
    let open = vncOpen
    let runner = VNCScreenSharingViewerRunner(
      displayId: display, open: { try await open(display) },
      arbitratedByServer: { [weak self] in self?.controlLease ?? false },
      setDesktopScale: { [client, weak self] scale in
        guard let request = self?.request(.setScale, viewerId: UUID(), displayId: display) else { return }
        var scaled = request
        scaled.scale = scale
        _ = try? await client.screenSharing(scaled)
      },
      makeSurface: makeSurface)
    vncRunners[display] = runner
    return runner
  }

  private func sleepUntilDeadline(since began: ContinuousClock.Instant) async throws {
    try await sleep(max(.zero, ScreenSharingConnectStage.deadline - (now() - began)))
    if client.isReconnecting { try await sleep(ScreenSharingConnectStage.reconnectingTunnelGrace) }
  }

  private func withinDeadline<Value: Sendable>(
    since began: ContinuousClock.Instant, failure: String, _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let deadline: @Sendable () async throws -> Void = { [self] in try await sleepUntilDeadline(since: began) }
    guard let value = try await ScreenSharingRace.value(of: operation, before: deadline) else {
      throw ViewerError(failure)
    }
    return value
  }

  private func run(display: String, emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void) async {
    let viewerId = UUID()
    var restarts = 0
    var started = false
    var message: String?
    attempts: while !Task.isCancelled {
      let (outcome, attemptStarted) = await attempt(
        viewerId: viewerId, display: display, restarts: restarts, emit: emit)
      started = started || attemptStarted
      switch outcome {
      case .lost:
        restarts += 1
        emit(.reconnecting)
      case .ended(let reason):
        message = reason
        break attempts
      case .cancelled:
        break attempts
      }
    }
    if let message { emit(.ended(message)) }
    if started {
      let stop = request(.stop, viewerId: viewerId)
      let client = client
      _ = await briefly { _ = try? await client.screenSharing(stop) }
    }
  }

  private func attempt(
    viewerId: UUID, display: String, restarts: Int, emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void
  ) async -> (Outcome, started: Bool) {
    let discovery =
      restarts == 0 ? discovered.flatMap { now() - $0.began < ScreenSharingConnectStage.deadline ? $0 : nil } : nil
    discovered = nil
    let attempt = ScreenSharingViewerAttempt(viewerId: viewerId, began: discovery?.began ?? now(), emit: emit)
    let body = Task { @MainActor [self] () -> Outcome in
      do {
        let capabilities: ServerScreenSharingReply
        if let discovery {
          capabilities = discovery.reply
        } else {
          let capabilitiesRequest = request(.capabilities, viewerId: viewerId)
          capabilities = try await ScreenSharingTransientRetry.run(sleep: sleep) { [client] in
            try await client.screenSharing(capabilitiesRequest)
          }
        }
        try Task.checkCancellation()
        guard capabilities.version == 1, ["available", "busy"].contains(capabilities.status) else {
          return .ended(capabilities.message ?? "Screen Sharing is unavailable on this Mac.")
        }
        guard capabilities.engines?.contains(ScreenSharingEngine.v2.rawValue) == true else {
          return .ended(Self.v2Unavailable)
        }
        return try await attemptV2(attempt: attempt, display: display, restarts: restarts, emit: emit)
      } catch {
        return isTaskCancellation(error) ? .cancelled : .ended(serverErrorMessage(error))
      }
    }
    attempt.body = body
    attempt.deadline = Task { @MainActor [self] in await expire(attempt, restarts: restarts) }
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        attempt.settle(with: continuation)
        Task { @MainActor in attempt.finish(await body.value) }
      }
    } onCancel: {
      body.cancel()
      Task { @MainActor in attempt.abort(.cancelled) }
    }
    attempt.close()
    return (await outcome(of: attempt, result: result), attempt.started)
  }

  private func expire(_ attempt: ScreenSharingViewerAttempt, restarts: Int) async {
    do {
      try await sleep(max(.zero, ScreenSharingConnectStage.stillConnectingAfter - (now() - attempt.began)))
      guard !attempt.ready, attempt.outcome == nil else { return }
      attempt.reportProgress()
      try await sleepUntilDeadline(since: attempt.began)
      while attempt.notice != nil, !attempt.ready, attempt.outcome == nil {
        while attempt.notice != nil, !attempt.ready, attempt.outcome == nil { try await sleep(heartbeatInterval) }
        try await sleepUntilDeadline(since: now())
      }
    } catch { return }
    guard !attempt.ready, attempt.outcome == nil else { return }
    let stage = attempt.stage
    Self.logger.error(
      "Viewer \(Self.tag(attempt.viewerId), privacy: .public) gave up at \(stage.rawValue, privacy: .public) after \(attempt.times.summary(at: self.now()), privacy: .public)"
    )
    attempt.abort(restarts > 0 && restarts < Self.maximumRestarts ? .lost : .ended(stage.failure))
  }

  private func outcome(of attempt: ScreenSharingViewerAttempt, result: Outcome) async -> Outcome {
    var outcome = Task.isCancelled ? .cancelled : (attempt.outcome ?? result)
    if attempt.transportEnded, attempt.started, !Task.isCancelled,
      let reason = await hostEndReason(viewerId: attempt.viewerId)
    {
      outcome = .ended(reason)
    }
    let tag = Self.tag(attempt.viewerId)
    switch outcome {
    case .ended(let reason):
      Self.logger.notice("Viewer \(tag, privacy: .public) ended: \(reason, privacy: .public)")
    case .lost:
      Self.logger.notice("Viewer \(tag, privacy: .public) lost the connection; reconnecting")
    case .cancelled:
      break
    }
    return outcome
  }

  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")
  private static let v2Unavailable =
    "The host Mac needs a newer version of Codevisor to share its screen. Update Codevisor on it, then retry."
  private static let hostFailed =
    "The host Mac couldn't start sharing its screen. Retry. If it keeps happening, quit and reopen Codevisor on the host Mac."

  private static let maximumRestarts = 3
  static let briefWait: Duration = .seconds(5)

  private static func tag(_ viewerId: UUID) -> String { String(viewerId.uuidString.prefix(8)) }

  private func open(
    _ session: any ScreenSharingViewingSession, attempt: ScreenSharingViewerAttempt, display: String, restarts: Int,
    emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void
  ) throws {
    let surface: any ScreenSharingViewerSurface
    do {
      try Task.checkCancellation()
      surface = try makeSurface(session)
    } catch {
      session.close()
      throw error
    }
    let endpoint = ScreenSharingViewerEndpoint(session: session, surface: surface, sound: sound, displayId: display)
    endpoint.dropsInjectedInput = ScreenSharingDisplayIdentity.isOnThisMac(display)
    attempt.endpoint = endpoint
    let now = now
    endpoint.onReady = { [weak session] in
      attempt.ready = true
      attempt.deadline?.cancel()
      let summary = attempt.times.summary(at: now())
      session?.metrics.label("connectTime", summary)
      Self.logger.notice(
        "Viewer \(Self.tag(attempt.viewerId), privacy: .public) first frame in \(summary, privacy: .public)")
      emit(.ready)
    }
    session.onConnectionChanged = { transport in
      guard ["failed", "disconnected", "closed"].contains(transport), attempt.outcome == nil else { return }
      attempt.transportEnded = true
      attempt.abort(
        (attempt.ready || restarts > 0) && restarts < Self.maximumRestarts && transport != "closed"
          ? .lost : .ended("The screen-sharing connection ended. Reconnect to continue."))
    }
    emit(.opened(endpoint))
  }

  private func heartbeats(
    attempt: ScreenSharingViewerAttempt, session: any ScreenSharingViewingSession, notice: String?,
    emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void
  ) async throws -> Outcome {
    var notice = notice
    attempt.notice = notice
    if notice != nil { emit(.hostNotice(notice)) }
    while true {
      try await sleep(heartbeatInterval)
      try Task.checkCancellation()
      let reply = try await client.screenSharing(request(.heartbeat, viewerId: attempt.viewerId))
      try Task.checkCancellation()
      guard reply.version == 1, ["connecting", "viewing"].contains(reply.status) else {
        return .ended(reply.message ?? "Screen sharing ended on the host Mac.")
      }
      if let failure = session.failure { return .ended(failure) }
      if reply.message != notice {
        notice = reply.message
        attempt.notice = notice
        emit(.hostNotice(notice))
      }
    }
  }

  private func attemptV2(
    attempt: ScreenSharingViewerAttempt, display: String, restarts: Int,
    emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void
  ) async throws -> Outcome {
    let tag = Self.tag(attempt.viewerId)
    attempt.enter(.connectingMedia, at: now())
    guard let address = await v2.address() else { return Self.connectFailed(restarts: restarts, at: .connectingMedia) }
    try Task.checkCancellation()
    let reply = try await startHost(attempt: attempt, display: display, restarts: restarts, media: address)
    guard reply.version == 1, reply.status == "connecting", let grant = reply.media else {
      return .ended(
        reply.message
          ?? (reply.status == "failed" ? Self.hostFailed : "This Mac cannot start screen sharing right now."))
    }

    attempt.enter(.connectingMedia, at: now())
    Self.logger.notice(
      "Viewer \(tag, privacy: .public) granted media (relay \(grant.relayUrl ?? "none", privacy: .public), \(grant.directAddrs.count) direct): \(attempt.times.summary(at: self.now()), privacy: .public)"
    )
    var session: any ScreenSharingV2StartableSession
    do {
      session = try await v2.connect(grant)
    } catch {
      guard !Task.isCancelled else { return .cancelled }
      Self.logger.error("Viewer \(tag, privacy: .public) media connect failed: \(error, privacy: .public)")
      return Self.connectFailed(restarts: restarts, at: .connectingMedia)
    }
    attempt.session = session
    guard attempt.outcome == nil, !Task.isCancelled else {
      session.close()
      return .cancelled
    }
    attempt.enter(.handshake, at: now())
    session.presentsTiles = true
    try open(session, attempt: attempt, display: display, restarts: restarts, emit: emit)
    do {
      try await session.start(token: grant.token)
    } catch {
      guard !Task.isCancelled else { return .cancelled }
      Self.logger.error("Viewer \(tag, privacy: .public) media handshake failed: \(error, privacy: .public)")
      return Self.connectFailed(restarts: restarts, at: .handshake)
    }
    if !attempt.ready { attempt.enter(.waitingForVideo, at: now()) }
    Self.logger.notice(
      "Viewer \(tag, privacy: .public) media session up: \(attempt.times.summary(at: self.now()), privacy: .public)")
    return try await heartbeats(attempt: attempt, session: session, notice: reply.message, emit: emit)
  }

  private func startHost(
    attempt: ScreenSharingViewerAttempt, display: String, restarts: Int, media: ServerScreenSharingMediaAddress
  ) async throws -> ServerScreenSharingReply {
    var start = request(restarts == 0 ? .start : .restart, viewerId: attempt.viewerId, displayId: display)
    start.engine = ScreenSharingEngine.v2.rawValue
    start.media = media
    start.chroma = await v2.chroma().rawValue
    attempt.started = true
    attempt.enter(.startingHost, at: now())
    Self.logger.notice(
      "Viewer \(Self.tag(attempt.viewerId), privacy: .public) \(restarts == 0 ? "starting" : "restarting", privacy: .public) \(display, privacy: .public): \(attempt.times.summary(at: self.now()), privacy: .public)"
    )
    let reply = try await ScreenSharingTransientRetry.run(sleep: sleep) { [client, start] in
      try await client.screenSharing(start)
    }
    try Task.checkCancellation()
    return reply
  }

  private static func connectFailed(restarts: Int, at stage: ScreenSharingConnectStage) -> Outcome {
    restarts > 0 && restarts < maximumRestarts ? .lost : .ended(stage.failure)
  }

  private func hostEndReason(viewerId: UUID) async -> String? {
    let heartbeat = request(.heartbeat, viewerId: viewerId)
    let client = client
    let reply = await briefly { try? await client.screenSharing(heartbeat) }
    guard let reply, reply.status == "failed" else { return nil }
    return reply.message
  }

  private func briefly<Value: Sendable>(_ work: @escaping @Sendable () async -> Value?) async -> Value? {
    let wait = Self.briefWait
    let value = try? await ScreenSharingRace.value(
      of: { await work() }, before: { try await Task.sleep(for: wait) }, cancellingLateWork: false)
    return value ?? nil
  }

  private func request(
    _ operation: ServerScreenSharingRequest.Operation, viewerId: UUID, displayId: String? = nil
  ) -> ServerScreenSharingRequest {
    .init(
      operation: operation, workspaceId: workspaceId, paneId: paneId, viewerId: viewerId,
      displayId: displayId ?? target)
  }

  private struct ViewerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
