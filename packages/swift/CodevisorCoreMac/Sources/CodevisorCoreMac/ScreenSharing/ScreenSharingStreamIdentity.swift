import CodevisorClient
import Foundation
import ScreenSharingV2

@MainActor
final class ScreenSharingStreamIdentity {
  typealias Owner = ScreenSharingStreamOwner
  typealias Request = ServerScreenSharingRequest
  typealias Reply = ServerScreenSharingReply

  static let rememberedEndings = 16

  private let hostKey: @MainActor () async -> String?
  private let now: @MainActor () -> TimeInterval
  private var challenges = ScreenSharingHostChallenges()
  private var starting: [Owner: UUID] = [:]
  private var endings: [(token: String, reply: Reply)] = []

  init(
    hostKey: @escaping @MainActor () async -> String? = { await ScreenSharingStreamIdentity.mediaEndpointKey() },
    now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.hostKey = hostKey
    self.now = now
  }

  func describing(_ reply: Reply, for request: Request) async -> Reply {
    var reply = reply
    guard Self.isIdentified(request), request.operation == .capabilities else { return reply }

    reply.abilities = [Reply.appSessions]
    if reply.status == "available" { reply.challenge = await challenge() }
    return reply
  }

  func refusal(toIdentify request: Request) -> Reply? {
    guard !Self.isIdentified(request) || request.operation == .restart else { return nil }

    return ScreenSharingHostRefusal.viewerUpdateNeeded(machine: ScreenSharingHostService.machineName()).reply
  }

  func refusal(toStart request: Request) async -> Reply? {
    guard request.app != nil, !challenges.redeem(provedBy: request, now: now()) else { return nil }

    return ScreenSharingHostChallenges.rejection(offering: await challenge())
  }

  func begin(_ request: Request, target: String) -> Owner? {
    guard let owner = Owner(starting: request, target: target) else { return nil }

    starting[owner] = request.viewerId
    return owner
  }

  func isStillStarting(_ request: Request, as owner: Owner) -> Bool {
    starting[owner] == request.viewerId
  }

  func finish(_ request: Request, as owner: Owner) {
    if starting[owner] == request.viewerId { starting[owner] = nil }
  }

  func token(for owner: Owner) -> String? {
    ScreenSharingHostChallenges.randomHex()
  }

  func owner<Session: ScreenSharingStreamSession>(
    heartbeating request: Request, among sessions: [Owner: Session]
  ) -> Owner? {
    holder(ofTheTokenIn: request, among: sessions)
  }

  func owner<Session: ScreenSharingStreamSession>(
    stoppedBy request: Request, among sessions: [Owner: Session]
  ) -> Owner? {
    guard request.session == nil else { return holder(ofTheTokenIn: request, among: sessions) }

    starting = starting.filter { $0.value != request.viewerId }
    return sessions.first { $0.value.attempt == request.viewerId }?.key
  }

  func remember(_ session: any ScreenSharingStreamSession, endedWith reply: Reply) {
    guard let token = session.token else { return }

    endings.append((token, reply))
    endings.removeFirst(max(0, endings.count - Self.rememberedEndings))
  }

  func ending(for request: Request) -> Reply? {
    guard let token = request.session else { return nil }

    return endings.last { Self.matches($0.token, token) }?.reply
  }

  static func mediaEndpointKey() async -> String? {
    guard let endpoint = await ScreenSharingMediaEndpoint.shared.ready() else { return nil }

    return ScreenSharingMediaEndpoint.address(of: endpoint).endpointId
  }

  private static func matches(_ token: String, _ candidate: String) -> Bool {
    ScreenSharingHostChallenges.token(token, matches: candidate)
  }

  private static func isIdentified(_ request: Request) -> Bool {
    switch request.operation {
    case .capabilities, .start, .restart, .setScale: request.app != nil
    case .heartbeat: request.session != nil
    case .stop: true
    }
  }

  private func holder<Session: ScreenSharingStreamSession>(
    ofTheTokenIn request: Request, among sessions: [Owner: Session]
  ) -> Owner? {
    guard let token = request.session else { return nil }

    return sessions.first { $0.value.token.map { Self.matches($0, token) } == true }?.key
  }

  private func challenge() async -> ServerScreenSharingChallenge? {
    guard let hostKey = await hostKey() else { return nil }

    return challenges.mint(hostKey: hostKey, now: now())
  }
}
