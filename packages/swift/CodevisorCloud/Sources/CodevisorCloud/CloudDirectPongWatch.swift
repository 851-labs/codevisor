import Foundation

struct CloudDirectPongWatch {
  static let maximumExtensions = 3

  private var pingSentAt: ContinuousClock.Instant?
  private var lastInboundAt: ContinuousClock.Instant?
  private var inboundSinceArmed = false
  private var extensions = 0

  mutating func pingSent() {
    pingSentAt = .now
    extensions = 0
    inboundSinceArmed = false
  }

  mutating func received() {
    lastInboundAt = .now
    inboundSinceArmed = true
  }

  mutating func extendsExpiredDeadline() -> Bool {
    guard inboundSinceArmed, extensions < Self.maximumExtensions else { return false }
    extensions += 1
    inboundSinceArmed = false
    return true
  }

  mutating func ponged() -> Duration? {
    defer { pingSentAt = nil }
    return pingSentAt?.duration(to: .now)
  }

  func diagnostics(openChannels: Int, path: String?) -> String {
    let now = ContinuousClock.now
    let ago: (ContinuousClock.Instant?) -> String = {
      $0.map { Self.seconds($0.duration(to: now)) + " ago" } ?? "never"
    }
    return
      "\(openChannels) open channels, last message \(ago(lastInboundAt)), ping sent \(ago(pingSentAt)), path \(path ?? "unknown")"
  }

  static func seconds(_ duration: Duration) -> String {
    String(format: "%.1f s", duration / .seconds(1))
  }
}
