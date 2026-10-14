import Foundation

struct LocalServerScheduler: Sendable {
  typealias Instant = ContinuousClock.Instant

  var now: @MainActor @Sendable () -> Instant
  var sleep: @MainActor @Sendable (Duration) async throws -> Void
  var sleepUntil: @MainActor @Sendable (Instant) async throws -> Void

  static let continuous = Self(
    now: { ContinuousClock.now },
    sleep: { try await Task.sleep(for: $0) },
    sleepUntil: { try await Task.sleep(until: $0, clock: .continuous) }
  )
}
