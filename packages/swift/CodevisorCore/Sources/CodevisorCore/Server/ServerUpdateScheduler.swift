import Foundation

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
