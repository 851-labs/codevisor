import CodevisorClient
import ScreenSharing
import ScreenSharingV2

@MainActor
final class ScreenSharingMediaSessionTransport: ScreenSharingTransport {
  struct Plan {
    var capabilities: ScreenSharingHostReply
    var intent: ScreenSharingStartIntent
    var preferredDisplayId: String?
  }

  private let host: ScreenSharingHostRequests
  private let connector: ScreenSharingV2Connector
  private let presentsTiles: Bool
  private let clock: ScreenSharingConnectionClock
  private var plan: Plan
  private var session: (any ScreenSharingV2StartableSession)?
  private var report: @MainActor (ScreenSharingTransportEvent) -> Void = { _ in }
  private let ends = AsyncStream<ScreenSharingAttemptEnd>.makeStream()
  private var beating: Task<Void, Never>?
  private var isClosed = false

  init(
    host: ScreenSharingHostRequests, machine: ScreenSharingMachine, clock: ScreenSharingConnectionClock, plan: Plan
  ) {
    self.host = host
    connector = machine.connector
    presentsTiles = machine.presentsTiles
    self.clock = clock
    self.plan = plan
  }

  func open(report: @escaping @MainActor (ScreenSharingTransportEvent) -> Void) async throws {
    self.report = report
    report(.entered(.connectingMedia))
    guard let address = await connector.address() else { throw ScreenSharingAttemptEnd.dropped(.networkBlocked) }

    try checkOpen()
    report(.entered(.startingHost))
    let chroma = await connector.chroma().rawValue
    try checkOpen()
    let (reply, grant) = try await granted(media: address, chroma: chroma, mayRefresh: true)
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

  func close() {
    isClosed = true
    beating?.cancel()
    ends.continuation.finish()
    session?.onConnectionChanged = nil
    session?.close()
    session = nil
  }

  private func granted(
    media: ServerScreenSharingMediaAddress, chroma: String, mayRefresh: Bool
  ) async throws -> (ScreenSharingHostReply, ServerScreenSharingMediaGrant) {
    let ownedByApp = plan.capabilities.ownsSessionsByApp
    let start = ScreenSharingHostRequests.Start(
      displayId: try displayId(ownedByApp: ownedByApp), media: media, chroma: chroma, intent: plan.intent,
      ownedByApp: ownedByApp)
    let reply = try await host.start(start)
    if let grant = reply.grant { return (reply, grant) }
    guard reply.lacksTheDisplay, !ownedByApp else { throw reply.end() }
    guard mayRefresh else { throw ScreenSharingAttemptEnd.refused(.noDisplay) }

    plan.capabilities = try await host.capabilities()
    try checkOpen()
    return try await granted(media: media, chroma: chroma, mayRefresh: false)
  }

  private func checkOpen() throws {
    if isClosed || Task.isCancelled { throw CancellationError() }
  }

  private func displayId(ownedByApp: Bool) throws -> String? {
    guard !ownedByApp else { return plan.preferredDisplayId }

    let displays = plan.capabilities.base.displays
    guard let display = displays.first(where: { $0.id == plan.preferredDisplayId }) ?? displays.first else {
      throw ScreenSharingAttemptEnd.refused(.noDisplay)
    }

    return display.id
  }

  private func announce(_ reply: ScreenSharingHostReply) {
    report(.notice(reply.base.message))
    guard let display = reply.display ?? requestedDisplay else { return }

    let displays = reply.base.displays.isEmpty ? plan.capabilities.base.displays : reply.base.displays
    report(.sharing(display: display, displays: displays))
  }

  private var requestedDisplay: ServerScreenSharingDisplay? {
    guard !plan.capabilities.ownsSessionsByApp else { return nil }

    let displays = plan.capabilities.base.displays
    return displays.first { $0.id == plan.preferredDisplayId } ?? displays.first
  }

  private func linking<Value>(_ work: () async throws -> Value) async throws -> Value {
    do {
      return try await work()
    } catch {
      throw isClosed || Task.isCancelled ? CancellationError() : ScreenSharingAttemptEnd.dropped(.networkBlocked)
    }
  }

  private func heartbeats() async -> ScreenSharingAttemptEnd? {
    var lastAnswer = clock.now()
    while !Task.isCancelled {
      guard (try? await clock.sleep(ScreenSharingConnectionDeadlines.heartbeatInterval)) != nil else { return nil }
      guard !Task.isCancelled else { return nil }

      do {
        guard let reply = try await host.heartbeat() else { return nil }
        guard reply.isSharing else { return host.heartbeatEnd(for: reply) }

        lastAnswer = clock.now()
        announce(reply)
      } catch {
        if let end = heartbeatFailed(error, lastAnswer: lastAnswer) { return end }
      }
    }
    return nil
  }

  private func heartbeatFailed(_ error: any Error, lastAnswer: ContinuousClock.Instant) -> ScreenSharingAttemptEnd? {
    guard !Task.isCancelled, !isTaskCancellation(error) else { return nil }

    if CodevisorServerClientError.isRefusal(error) {
      return .dropped(.unclassified(message: serverErrorMessage(error)))
    }
    let silence = clock.now() - lastAnswer
    return silence >= ScreenSharingConnectionDeadlines.failedHeartbeats ? .dropped(.cantReach) : nil
  }
}
