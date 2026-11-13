import CodevisorClient
import Foundation

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
    var displayId: String?
    var media: ServerScreenSharingMediaAddress
    var chroma: String
    var intent: ScreenSharingStartIntent
    var ownedByApp: Bool
  }

  private let machine: ScreenSharingMachine
  private let sleep: @Sendable (Duration) async throws -> Void
  private var started: Owner?
  private var registered: ScreenSharingLegacyIdentity?

  init(machine: ScreenSharingMachine, sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.machine = machine
    self.sleep = sleep
  }

  var isLinkReconnecting: Bool { machine.channel.isReconnecting }

  func capabilities() async throws -> ScreenSharingHostReply {
    let asker = Owner(workspaceId: machine.installId, paneId: machine.installId, viewerId: UUID(), app: nil)
    let reply = try await retrying(request(.capabilities, from: asker))
    guard reply.canShare else { throw reply.end() }

    return reply
  }

  func start(_ start: Start) async throws -> ScreenSharingHostReply {
    let owner = try await owner(for: start)
    try Task.checkCancellation()
    if let started, !started.holdsTheSameSession(as: owner) { await stop() }
    var request = request(.start, from: owner, displayId: start.displayId)
    request.base.engine = ScreenSharingHostRequest.engine
    request.base.media = start.media
    request.base.chroma = start.chroma
    if owner.app != nil { request.intent = start.intent }
    started = owner
    do {
      return try await retrying(request)
    } catch {
      if CodevisorServerClientError.isRefusal(error) { registered = nil }
      throw error
    }
  }

  func heartbeat() async throws -> ScreenSharingHostReply? {
    guard let started else { return nil }

    do {
      return try await machine.channel.send(request(.heartbeat, from: started))
    } catch {
      if CodevisorServerClientError.isRefusal(error) { registered = nil }
      throw error
    }
  }

  func heartbeatEnd(for reply: ScreenSharingHostReply) -> ScreenSharingAttemptEnd {
    reply.end(heartbeatToOldHost: started?.app == nil)
  }

  func whyItEnded() async -> ScreenSharingFailureReason? {
    guard let reply = try? await heartbeat(), !reply.isSharing else { return nil }
    guard case .refused(let reason) = heartbeatEnd(for: reply) else { return nil }

    return reason
  }

  func stop() async {
    guard let started else { return }

    self.started = nil
    _ = try? await machine.channel.send(request(.stop, from: started))
  }

  private func owner(for start: Start) async throws -> Owner {
    let viewerId = UUID()
    guard !start.ownedByApp else {
      let app = ScreenSharingHostRequest.App(key: start.media.endpointId, name: machine.appName)
      return Owner(workspaceId: machine.installId, paneId: machine.installId, viewerId: viewerId, app: app)
    }
    guard let workspaceId = machine.liveWorkspace() else { throw ScreenSharingAttemptEnd.refused(.updateNeeded) }

    let identity = ScreenSharingLegacyIdentity(workspaceId: workspaceId, installId: machine.installId)
    if registered != identity {
      try await machine.channel.registerDesktopPane(identity)
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
    let channel = machine.channel
    return try await ScreenSharingRequestRetry.run(sleep: sleep) { try await channel.send(request) }
  }
}
