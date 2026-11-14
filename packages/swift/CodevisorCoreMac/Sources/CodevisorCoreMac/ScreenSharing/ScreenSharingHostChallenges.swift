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

  static func randomHex() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
  }
}
