import CodevisorClient
import ScreenSharing
import ScreenSharingV2

@MainActor
final class ScreenSharingMediaSessionTransport: ScreenSharingTransport {
  struct Plan {
    var capabilities: ScreenSharingHostReply
    var intent: ServerScreenSharingRequest.Intent
    var preferredDisplayId: String?
  }

  private let host: ScreenSharingHostRequests
  private let connector: ScreenSharingV2Connector
  private let presentsTiles: Bool
  private let target: String?
  private let heartbeatInterval: Duration
  private let clock: ScreenSharingConnectionClock
  private var plan: Plan
  private var session: (any ScreenSharingV2StartableSession)?
  private var report: @MainActor (ScreenSharingTransportEvent) -> Void = { _ in }
  private let ends = AsyncStream<ScreenSharingAttemptEnd>.makeStream()
  private var beating: Task<Void, Never>?
  private var beats: [Task<Void, Never>] = []
  private var lastAnswer: ContinuousClock.Instant
  private var isClosed = false
  private var switcher = ScreenSharingDisplaySwitcher()
  private var backstop: Task<Void, Never>?

  init(
    host: ScreenSharingHostRequests, machine: ScreenSharingMachine, clock: ScreenSharingConnectionClock, plan: Plan
  ) {
    self.host = host
    connector = machine.connector
    presentsTiles = machine.presentsTiles
    target = machine.target
    heartbeatInterval = machine.heartbeatInterval
    self.clock = clock
    self.plan = plan
    lastAnswer = clock.now()
  }

  func open(report: @escaping @MainActor (ScreenSharingTransportEvent) -> Void) async throws {
    self.report = report
    report(.entered(.connectingMedia))
    guard let address = await connector.address() else { throw ScreenSharingAttemptEnd.dropped(.networkBlocked) }

    try checkOpen()
    report(.entered(.startingHost))
    let chroma = await connector.chroma().rawValue
    try checkOpen()
    let (reply, grant) = try await granted(media: address, chroma: chroma)
    try checkOpen()
    announce(reply)
    report(.entered(.connectingMedia))
    let session = try await linking { try await self.connector.connect(grant) }
    guard !isClosed, !Task.isCancelled else {
      session.close()
      throw CancellationError()
    }

    self.session = session
    report(.entered(.handshake))
    session.presentsTiles = presentsTiles
    session.onConnectionChanged = { [ends] state in
      if ["failed", "disconnected", "closed"].contains(state) { ends.continuation.yield(.dropped(.networkBlocked)) }
    }
    report(.opened(session))
    try await linking { try await session.start(token: grant.token) }
    report(.entered(.waitingForVideo))
  }

  func monitor() async -> ScreenSharingAttemptEnd? {
    beating = Task { [weak self, ends] in
      guard let end = await self?.heartbeats() else { return }

      ends.continuation.yield(end)
    }
    return await withTaskCancellationHandler {
      for await end in ends.stream { return end }
      return nil
    } onCancel: {
      ends.continuation.finish()
    }
  }

  func switchDisplay(to displayId: String) -> Bool {
    guard canSwitchDisplay else { return false }

    switcher.want(displayId)
    backstop?.cancel()
    backstop = Task { [weak self, clock] in
      guard (try? await clock.sleep(ScreenSharingConnectionDeadlines.displaySwitch)) != nil else { return }

      self?.giveUp(on: displayId)
    }
    if !switcher.isCarrying { beats.append(Task { [weak self] in await self?.beat() }) }
    return true
  }

  func close() {
    isClosed = true
    backstop?.cancel()
    beating?.cancel()
    for beat in beats { beat.cancel() }
    ends.continuation.finish()
    session?.onConnectionChanged = nil
    session?.close()
    session = nil
  }

  private func granted(
    media: ServerScreenSharingMediaAddress, chroma: String
  ) async throws -> (ScreenSharingHostReply, ServerScreenSharingMediaGrant) {
    let start = ScreenSharingHostRequests.Start(
      capabilities: plan.capabilities, displayId: target ?? plan.preferredDisplayId, media: media, chroma: chroma,
      intent: plan.intent)
    let reply = try await host.start(start)
    guard let grant = reply.grant else { throw host.refusal(reply) }

    return (reply, grant)
  }

  private func checkOpen() throws {
    if isClosed || Task.isCancelled { throw CancellationError() }
  }

  private var canSwitchDisplay: Bool {
    target == nil && host.holdsASessionToken && beating != nil && !isClosed
  }

  private func giveUp(on displayId: String) {
    guard switcher.giveUp(on: displayId), !isClosed else { return }

    report(.displaySwitch(.init(displayId: displayId, phase: .unavailable(message: nil))))
  }

  private func announce(_ reply: ScreenSharingHostReply) {
    if !reply.isStillSwitchingDisplay, !reply.cannotSwitchDisplay { report(.notice(reply.base.message)) }
    guard let display = reply.base.display ?? requestedDisplay else { return }

    let displays = reply.base.displays.isEmpty ? plan.capabilities.base.displays : reply.base.displays
    report(.sharing(display: display, displays: displays))
  }

  private var requestedDisplay: ServerScreenSharingDisplay? {
    guard let target else { return nil }

    return plan.capabilities.base.displays.first { $0.id == target }
  }

  private func linking<Value>(_ work: () async throws -> Value) async throws -> Value {
    do {
      return try await work()
    } catch {
      throw isClosed || Task.isCancelled ? CancellationError() : ScreenSharingAttemptEnd.dropped(.networkBlocked)
    }
  }

  private func heartbeats() async -> ScreenSharingAttemptEnd? {
    lastAnswer = clock.now()
    while !Task.isCancelled {
      guard (try? await clock.sleep(heartbeatInterval)) != nil else { return nil }
      guard !Task.isCancelled else { return nil }

      let silence = clock.now() - lastAnswer
      if silence >= ScreenSharingConnectionDeadlines.failedHeartbeats { return .dropped(.cantReach) }
      beats.append(Task { [weak self] in await self?.beat() })
    }
    return nil
  }

  private func beat() async {
    let beat = switcher.beginBeat()
    defer {
      if switcher.finish(beat), !isClosed { beats.append(Task { [weak self] in await self?.beat() }) }
    }
    do {
      guard let reply = try await host.heartbeat(switchingTo: beat.carrying), !isClosed else { return }
      guard reply.isSharing else {
        ends.continuation.yield(host.heartbeatEnd(for: reply))
        return
      }

      lastAnswer = clock.now()
      read(reply, of: beat)
    } catch {
      guard !isClosed, CodevisorServerClientError.isRefusal(error) else { return }

      ends.continuation.yield(.dropped(.unclassified(message: serverErrorMessage(error))))
    }
  }

  private func read(_ reply: ScreenSharingHostReply, of beat: ScreenSharingDisplaySwitcher.Beat) {
    let reading = switcher.read(reply, of: beat)
    if reading.showsDisplay { announce(reply) }
    guard let result = reading.result else { return }

    backstop?.cancel()
    report(.displaySwitch(result))
  }
}
