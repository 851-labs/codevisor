import CodevisorClient
import Foundation
import ScreenSharingV2

@MainActor
final class ScreenSharingHostRequests {
  struct Owner: Equatable {
    let workspaceId: UUID
    let paneId: UUID
    let viewerId: UUID
    let app: ScreenSharingHostRequest.App?

    func holdsTheSameSession(as other: Owner) -> Bool {
      if let app, let otherApp = other.app { return app.key == otherApp.key }
      return app == nil && other.app == nil && workspaceId == other.workspaceId && paneId == other.paneId
    }
  }

  struct Start {
    var capabilities: ScreenSharingHostReply
    var displayId: String?
    var media: ServerScreenSharingMediaAddress
    var chroma: String
    var intent: ScreenSharingStartIntent
  }

  private let machine: ScreenSharingMachine
  private let clock: ScreenSharingConnectionClock
  private var started: Owner?
  private var owesAnExplanation = false
  private var registered: ScreenSharingLegacyIdentity?

  init(machine: ScreenSharingMachine, clock: ScreenSharingConnectionClock) {
    self.machine = machine
    self.clock = clock
  }

  var isLinkReconnecting: Bool { machine.channel().isReconnecting }

  func capabilities() async throws -> ScreenSharingHostReply {
    let asker = Owner(workspaceId: machine.installId, paneId: machine.installId, viewerId: UUID(), app: nil)
    let reply = try await retrying(request(.capabilities, from: asker))
    guard reply.canShare else { throw reply.end() }

    return reply
  }

  func start(_ start: Start) async throws -> ScreenSharingHostReply {
    let owner = try await owner(for: start)
    try Task.checkCancellation()
    if let previous = takeStarted(), !previous.holdsTheSameSession(as: owner) { await stop(previous) }
    var request = request(.start, from: owner, displayId: start.displayId)
    request.base.engine = ScreenSharingHostRequest.engine
    request.base.media = start.media
    request.base.chroma = start.chroma
    if owner.app != nil { request.intent = start.intent }
    started = owner
    do {
      let reply = try await retrying(request)
      if started != owner, reply.grant != nil { await stop(owner) }
      return reply
    } catch {
      if CodevisorServerClientError.isRefusal(error) { registered = nil }
      throw error
    }
  }

  func heartbeat() async throws -> ScreenSharingHostReply? {
    guard let started else { return nil }

    do {
      return try await machine.channel().send(request(.heartbeat, from: started))
    } catch {
      if CodevisorServerClientError.isRefusal(error) { registered = nil }
      throw error
    }
  }

  func heartbeatEnd(for reply: ScreenSharingHostReply) -> ScreenSharingAttemptEnd {
    reply.end(heartbeatToOldHost: started?.app == nil)
  }

  func sessionDropped() {
    owesAnExplanation = started != nil
  }

  func whyItEnded() async throws -> ScreenSharingFailureReason? {
    guard owesAnExplanation else { return nil }

    let reply: ScreenSharingHostReply?
    do {
      reply = try await heartbeat()
    } catch where CodevisorServerClientError.isRefusal(error) {
      reply = nil
    }
    owesAnExplanation = false
    guard let reply, !reply.isSharing, case .refused(let reason) = heartbeatEnd(for: reply) else { return nil }

    return reason
  }

  func takeStarted() -> Owner? {
    defer {
      started = nil
      owesAnExplanation = false
    }
    return started
  }

  func stop(_ owner: Owner) async {
    let (channel, request, sleep) = (machine.channel(), request(.stop, from: owner), clock.sleep)
    _ = try? await ScreenSharingRace.value(
      of: { try await channel.send(request) },
      before: { try await sleep(ScreenSharingConnectionDeadlines.stopRequest) }, cancellingLateWork: false)
  }

  private func owner(for start: Start) async throws -> Owner {
    let viewerId = UUID()
    guard !start.capabilities.ownsSessionsByApp else {
      let app = ScreenSharingHostRequest.App(key: start.media.endpointId, name: machine.appName)
      return Owner(workspaceId: machine.installId, paneId: machine.installId, viewerId: viewerId, app: app)
    }
    guard let workspaceId = machine.liveWorkspace() else { throw ScreenSharingAttemptEnd.refused(.noWorkspace) }

    let identity = ScreenSharingLegacyIdentity(workspaceId: workspaceId, installId: machine.installId)
    if registered != identity {
      try await machine.channel().registerDesktopPane(identity)
      registered = identity
    }
    return Owner(workspaceId: identity.workspaceId, paneId: identity.paneId, viewerId: viewerId, app: nil)
  }

  private func request(
    _ operation: ServerScreenSharingRequest.Operation, from owner: Owner, displayId: String? = nil
  ) -> ScreenSharingHostRequest {
    let base = ServerScreenSharingRequest(
      operation: operation, workspaceId: owner.workspaceId, paneId: owner.paneId, viewerId: owner.viewerId,
      displayId: displayId)
    return ScreenSharingHostRequest(base, app: owner.app)
  }

  private func retrying(_ request: ScreenSharingHostRequest) async throws -> ScreenSharingHostReply {
    let channel = machine.channel()
    return try await ScreenSharingRequestRetry.run(sleep: clock.sleep) { try await channel.send(request) }
  }
}
