nonisolated enum RetryBackoff {
  private static let maximumDoublings = 6
  private static let maximumMultiplier = 60

  static func multiplier(afterFailures failures: Int) -> Int {
    min(maximumMultiplier, 1 << min(failures, maximumDoublings))
  }
}
