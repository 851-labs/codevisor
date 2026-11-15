import CodevisorClient
import Foundation

struct ScreenSharingHostChallenges {
  static let lifetime: TimeInterval = 120
  static let limit = 256

  private var live: [(nonce: String, hostKey: String, expiresAt: TimeInterval)] = []

  mutating func mint(hostKey: String, now: TimeInterval) -> ServerScreenSharingChallenge {
    live.removeAll { $0.expiresAt <= now }
    if live.count >= Self.limit { live.removeFirst(live.count - Self.limit + 1) }
    let nonce = Self.randomHex()
    live.append((nonce, hostKey, now + Self.lifetime))
    return .init(hostKey: hostKey, nonce: nonce)
  }

  mutating func redeem(_ nonce: String, now: TimeInterval) -> String? {
    guard let index = live.firstIndex(where: { $0.nonce == nonce.lowercased() }) else { return nil }

    let challenge = live.remove(at: index)
    return challenge.expiresAt > now ? challenge.hostKey : nil
  }

  mutating func redeem(provedBy request: ServerScreenSharingRequest, now: TimeInterval) -> Bool {
    guard let proof = request.proof, let hostKey = redeem(proof.nonce, now: now) else { return false }

    return proof.proves(request, to: hostKey)
  }

  static func rejection(offering fresh: ServerScreenSharingChallenge?) -> ServerScreenSharingReply {
    var reply = ServerScreenSharingReply(
      status: "failed", message: "This Mac couldn't confirm which device is asking. Try again.")
    reply.reason = .proofRejected
    reply.challenge = fresh
    return reply
  }

  static func token(_ token: String, matches candidate: String) -> Bool {
    let mine = Array(token.utf8)
    let theirs = Array(candidate.lowercased().utf8)
    return mine.count == theirs.count && zip(mine, theirs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  static func randomHex() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
  }
}
