import Foundation

public struct ServerHarnessUsagePace: Equatable, Sendable {
  public enum Outlook: Equatable, Sendable {
    case lastsUntilReset
    case runsOut(Date)
  }

  public static let minimumElapsedPercent = 3.0

  public let expectedPercent: Double
  public let reservePercent: Double
  public let outlook: Outlook
}

extension ServerHarnessUsageWindow {
  public func pace(now: Date) -> ServerHarnessUsagePace? {
    guard let durationMinutes, durationMinutes > 0,
      let resetsAt = resetsAt.flatMap({ try? ServerDateCoding.date(from: $0) })
    else { return nil }
    let duration = durationMinutes * 60
    let remaining = resetsAt.timeIntervalSince(now)
    guard remaining > 0, remaining <= duration else { return nil }
    let elapsed = duration - remaining
    let expected = elapsed / duration * 100
    guard expected >= ServerHarnessUsagePace.minimumElapsedPercent else { return nil }
    let used = min(max(usedPercent, 0), 100)
    return ServerHarnessUsagePace(
      expectedPercent: expected,
      reservePercent: expected - used,
      outlook: Self.outlook(used: used, elapsed: elapsed, remaining: remaining, now: now)
    )
  }

  private static func outlook(
    used: Double, elapsed: TimeInterval, remaining: TimeInterval, now: Date
  ) -> ServerHarnessUsagePace.Outlook {
    guard used > 0 else { return .lastsUntilReset }
    let untilEmpty = (100 - used) / (used / elapsed)
    return untilEmpty >= remaining ? .lastsUntilReset : .runsOut(now.addingTimeInterval(untilEmpty))
  }
}
