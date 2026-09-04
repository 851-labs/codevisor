import Foundation

/// Supplies one monotonic time source for server-update deadlines and sleeps.
/// Tests advance virtual time; production keeps the continuous-clock deadline.
public struct ServerUpdateScheduler: Sendable {
  typealias Instant = ContinuousClock.Instant
  typealias Now = @MainActor @Sendable () -> Instant
  typealias Sleep = @MainActor @Sendable (_ interval: Duration) async throws -> Void

  let now: Now
  let sleep: Sleep

  init(now: @escaping Now, sleep: @escaping Sleep) {
    self.now = now
    self.sleep = sleep
  }

  public static let continuous = Self(
    now: { ContinuousClock.now },
    sleep: { interval in
      try await Task.sleep(for: interval)
    }
  )
}
