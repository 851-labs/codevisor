import Foundation

public struct AppUpdateProgressThrottle: Sendable {
  public static let interval: Duration = .milliseconds(250)

  private var last: (message: String?, fraction: Double?, at: ContinuousClock.Instant)?

  public init() {}

  public mutating func shouldReport(
    message: String?,
    fraction: Double?,
    at now: ContinuousClock.Instant
  ) -> Bool {
    guard let last else { return record(message, fraction, now) }
    if last.message != message || Self.percent(last.fraction) != Self.percent(fraction) {
      return record(message, fraction, now)
    }
    guard last.fraction != fraction, last.at.duration(to: now) >= Self.interval else { return false }
    return record(message, fraction, now)
  }

  public mutating func reset() {
    last = nil
  }

  private mutating func record(_ message: String?, _ fraction: Double?, _ now: ContinuousClock.Instant) -> Bool {
    last = (message, fraction, now)
    return true
  }

  private static func percent(_ fraction: Double?) -> Int? {
    guard let fraction, fraction.isFinite else { return nil }
    return Int((min(1, max(0, fraction)) * 100).rounded(.down))
  }
}
