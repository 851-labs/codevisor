import CodevisorClient
import Foundation
import ScreenSharingV2

extension ScreenSharingHostService {
  static let rememberedEndedSessions = 16

  func startsAppSession(_ request: ServerScreenSharingRequest) -> Bool {
    request.app != nil && [.start, .restart].contains(request.operation)
  }

  func provesItsKey(_ request: ServerScreenSharingRequest) -> Bool {
    guard let proof = request.proof,
      let hostKey = challenges.redeem(proof.nonce, now: ProcessInfo.processInfo.systemUptime)
    else { return false }

    return proof.proves(request, to: hostKey)
  }

  func challenge() async -> ServerScreenSharingChallenge? {
    guard let endpoint = await mediaEndpointHandle() else { return nil }

    let hostKey = ScreenSharingMediaEndpoint.address(of: endpoint).endpointId
    return challenges.mint(hostKey: hostKey, now: ProcessInfo.processInfo.systemUptime)
  }

  func proofRejected() async -> ServerScreenSharingReply {
    var reply = ServerScreenSharingReply(
      status: "failed", message: "This Mac couldn't confirm which device is asking. Try again.")
    reply.reason = .proofRejected
    reply.challenge = await challenge()
    return reply
  }

  func stops(_ request: ServerScreenSharingRequest, pending owner: Owner) -> Bool {
    request.session == nil && owner.isAttempt(of: request)
  }

  func stops(_ request: ServerScreenSharingRequest, _ session: ScreenSharingHostSession) -> Bool {
    guard let token = request.session else { return session.owner.isAttempt(of: request) }

    return session.owner.appKey != nil && session.hasToken(token)
  }

  func formerOwner(_ request: ServerScreenSharingRequest) -> Owner? {
    guard let token = request.session else { return Owner(paneOf: request) }

    return endedSessions.last { $0.token == token.lowercased() }?.owner
  }

  func rememberEnded(_ session: ScreenSharingHostSession) {
    guard session.owner.appKey != nil else { return }

    endedSessions.append((session.sessionToken, session.owner))
    endedSessions.removeFirst(max(0, endedSessions.count - Self.rememberedEndedSessions))
  }
}
