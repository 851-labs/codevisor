import Foundation

public struct RetryPolicy: Sendable {
  public static let standard = RetryPolicy()

  private static let maximumDoublings = 5

  let clock: any Clock<Duration>
  private let first: Duration
  private let longest: Duration
  private let jitter: Double

  public init(
    clock: any Clock<Duration> = ContinuousClock(),
    first: Duration = .seconds(1),
    longest: Duration = .seconds(30),
    jitter: Double = 0.2
  ) {
    self.clock = clock
    self.first = first
    self.longest = longest
    self.jitter = jitter
  }

  public func delay(afterFailures failures: Int, roll: Double = .random(in: -1...1)) -> Duration {
    backoff(afterFailures: failures) * (1 + jitter * roll)
  }

  private func backoff(afterFailures failures: Int) -> Duration {
    let doublings = min(max(failures - 1, 0), Self.maximumDoublings)
    return min(first * (1 << doublings), longest)
  }
}
