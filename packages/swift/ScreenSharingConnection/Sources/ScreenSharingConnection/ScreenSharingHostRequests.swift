import CodevisorClient
import Foundation
import ScreenSharingV2

@MainActor
final class ScreenSharingHostRequests {
  struct Owner {
    let viewerId: UUID
    var session: String?
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

  init(machine: ScreenSharingMachine, clock: ScreenSharingConnectionClock) {
    self.machine = machine
    self.clock = clock
  }

  var isLinkReconnecting: Bool { machine.channel().isReconnecting }

  static func capabilities(of machine: ScreenSharingMachine) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: .capabilities, workspaceId: machine.installId, paneId: machine.installId, viewerId: UUID(),
      displayId: machine.target)
    request.app = app(of: machine)
    return request
  }

  func capabilities() async throws -> ScreenSharingHostReply {
    let reply = try await retrying(Self.capabilities(of: machine))
    guard reply.isCurrentHost(forTarget: machine.target != nil) else {
      throw ScreenSharingAttemptEnd.refused(.updateNeeded)
    }
    guard reply.canShare else { throw refusal(reply) }

    return reply
  }

  func refusal(_ reply: ScreenSharingHostReply) -> ScreenSharingAttemptEnd {
    machine.target == nil ? reply.end() : reply.targetRefusal()
  }

  func start(_ start: Start) async throws -> ScreenSharingHostReply {
    guard let challenge = start.capabilities.appChallenge else { throw ScreenSharingAttemptEnd.refused(.updateNeeded) }

    let owner = Owner(viewerId: UUID())
    _ = takeStarted()
    started = owner
    let (reply, answered) = try await send(start, from: owner, answering: challenge)
    var granted = owner
    granted.session = reply.base.session
    if started?.viewerId == owner.viewerId {
      started = granted
    } else if reply.grant != nil {
      await stop(granted)
    }
    if let grant = reply.grant, grant.endpointId.lowercased() != answered.hostKey.lowercased() {
      throw ScreenSharingAttemptEnd.refused(.unclassified(message: Self.wrongHost))
    }
    return reply
  }

  var holdsASessionToken: Bool { started?.session != nil }

  func heartbeat(switchingTo displayId: String? = nil) async throws -> ScreenSharingHostReply? {
    guard let started else { return nil }

    var request = request(.heartbeat, from: started)
    if let displayId, started.session != nil, machine.target == nil { request.displayId = displayId }
    return ScreenSharingHostReply(try await machine.channel().send(request))
  }

  func heartbeatEnd(for reply: ScreenSharingHostReply) -> ScreenSharingAttemptEnd {
    reply.end()
  }

  func sessionDropped() {
    owesAnExplanation = started != nil
  }

  func whyItEnded() async throws -> ScreenSharingAttemptEnd? {
    guard owesAnExplanation else { return nil }

    let reply: ScreenSharingHostReply?
    do {
      reply = try await heartbeat()
    } catch  where CodevisorServerClientError.isRefusal(error) {
      reply = nil
    }
    owesAnExplanation = false
    guard let reply, !reply.isSharing else { return nil }

    guard case .refused(let reason) = heartbeatEnd(for: reply) else { return nil }

    return .refused(reason)
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

  private static func app(of machine: ScreenSharingMachine) -> ServerScreenSharingApp {
    ServerScreenSharingApp(key: machine.signer.key, name: machine.appName)
  }

  private func send(
    _ start: Start, from owner: Owner, answering challenge: ServerScreenSharingChallenge
  ) async throws -> (reply: ScreenSharingHostReply, answered: ServerScreenSharingChallenge) {
    var request = request(.start, from: owner)
    request.displayId = machine.target ?? start.displayId
    request.engine = ScreenSharingHostReply.engine
    request.media = start.media
    request.chroma = start.chroma
    request.app = Self.app(of: machine)
    request.intent = start.intent
    return try await sendSigned(request, answering: challenge, resendsLeft: Self.signedStartResends)
  }

  private func sendSigned(
    _ start: ServerScreenSharingRequest, answering challenge: ServerScreenSharingChallenge, resendsLeft: Int
  ) async throws -> (reply: ScreenSharingHostReply, answered: ServerScreenSharingChallenge) {
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
      operation: operation, workspaceId: machine.installId, paneId: machine.installId, viewerId: owner.viewerId,
      displayId: machine.target)
    request.session = owner.session
    return request
  }

  private func retrying(_ request: ServerScreenSharingRequest) async throws -> ScreenSharingHostReply {
    let channel = machine.channel()
    return ScreenSharingHostReply(
      try await ScreenSharingRequestRetry.run(sleep: clock.sleep) { try await channel.send(request) })
  }
}
