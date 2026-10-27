import Foundation

public struct CloudRosterRefreshThrottle: Sendable {
  public let interval: Duration
  private var lastRefresh: ContinuousClock.Instant?

  public init(interval: Duration = .seconds(30)) {
    self.interval = interval
  }

  public mutating func allowsRefresh(at now: ContinuousClock.Instant) -> Bool {
    if let lastRefresh, now - lastRefresh < interval { return false }
    lastRefresh = now
    return true
  }
}
