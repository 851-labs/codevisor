import CodevisorClient
import Foundation
import ScreenSharingV2

@MainActor
final class ScreenSharingHostRequests {
  struct Owner {
    let workspaceId: UUID
    let paneId: UUID
    let viewerId: UUID
    let app: ServerScreenSharingApp?
    var session: String?

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
    var intent: ServerScreenSharingRequest.Intent
  }

  static let signedStartResends = 2
  static let wrongHost =
    "The video address doesn't belong to the machine that was asked, so nothing was connected. Retry."

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
    var request = ServerScreenSharingRequest(
      operation: .capabilities, workspaceId: machine.installId, paneId: machine.installId, viewerId: UUID())
    request.app = app
    let reply = try await retrying(request)
    guard reply.canShare else { throw reply.end() }

    return reply
  }

  func start(_ start: Start) async throws -> ScreenSharingHostReply {
    let owner = try await owner(for: start)
    try Task.checkCancellation()
    if let previous = takeStarted(), !previous.holdsTheSameSession(as: owner) { await stop(previous) }
    started = owner
    do {
      let (reply, challenge) = try await send(start, from: owner)
      var granted = owner
      granted.session = reply.base.session
      if started?.viewerId == owner.viewerId {
        started = granted
      } else if reply.grant != nil {
        await stop(granted)
      }
      if let challenge, let grant = reply.grant, grant.endpointId.lowercased() != challenge.hostKey.lowercased() {
        throw ScreenSharingAttemptEnd.refused(.unclassified(message: Self.wrongHost))
      }
      return reply
    } catch {
      if CodevisorServerClientError.isRefusal(error) { registered = nil }
      throw error
    }
  }

  func heartbeat() async throws -> ScreenSharingHostReply? {
    guard let started else { return nil }

    do {
      return ScreenSharingHostReply(try await machine.channel().send(request(.heartbeat, from: started)))
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
    } catch  where CodevisorServerClientError.isRefusal(error) {
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

  private var app: ServerScreenSharingApp {
    ServerScreenSharingApp(key: machine.signer.key, name: machine.appName)
  }

  private func owner(for start: Start) async throws -> Owner {
    let viewerId = UUID()
    guard !start.capabilities.ownsSessionsByApp else {
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

  private func send(
    _ start: Start, from owner: Owner
  ) async throws -> (ScreenSharingHostReply, ServerScreenSharingChallenge?) {
    var request = request(.start, from: owner)
    request.displayId = start.displayId
    request.engine = ScreenSharingHostReply.engine
    request.media = start.media
    request.chroma = start.chroma
    guard let challenge = start.capabilities.appChallenge, let app = owner.app else {
      return (try await retrying(request), nil)
    }

    request.app = app
    request.intent = start.intent
    return try await sendSigned(request, answering: challenge, resendsLeft: Self.signedStartResends)
  }

  private func sendSigned(
    _ start: ServerScreenSharingRequest, answering challenge: ServerScreenSharingChallenge, resendsLeft: Int
  ) async throws -> (ScreenSharingHostReply, ServerScreenSharingChallenge?) {
    var request = start
    request.proof = try proof(of: start, answering: challenge)
    let reply: ScreenSharingHostReply
    do {
      reply = ScreenSharingHostReply(try await machine.channel().send(request))
    } catch  where ScreenSharingRequestRetry.isTransient(error) && resendsLeft > 0 {
      guard let fresh = try await capabilities().appChallenge else { throw error }

      return try await sendSigned(start, answering: fresh, resendsLeft: resendsLeft - 1)
    }
    guard reply.rejectsTheProof, resendsLeft > 0, let fresh = reply.challenge else { return (reply, challenge) }

    return try await sendSigned(start, answering: fresh, resendsLeft: resendsLeft - 1)
  }

  private func proof(
    of start: ServerScreenSharingRequest, answering challenge: ServerScreenSharingChallenge
  ) throws -> ServerScreenSharingProof {
    do {
      return try ServerScreenSharingProof(of: start, answering: challenge, signer: machine.signer)
    } catch {
      throw ScreenSharingAttemptEnd.refused(.unclassified(message: serverErrorMessage(error)))
    }
  }

  private func request(
    _ operation: ServerScreenSharingRequest.Operation, from owner: Owner
  ) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: operation, workspaceId: owner.workspaceId, paneId: owner.paneId, viewerId: owner.viewerId)
    request.session = owner.session
    return request
  }

  private func retrying(_ request: ServerScreenSharingRequest) async throws -> ScreenSharingHostReply {
    let channel = machine.channel()
    return ScreenSharingHostReply(
      try await ScreenSharingRequestRetry.run(sleep: clock.sleep) { try await channel.send(request) })
  }
}
