public struct ScreenSharingConnectionClock: Sendable {
  public var sleep: @Sendable (Duration) async throws -> Void
  public var now: @Sendable () -> ContinuousClock.Instant

  public static let live = Self(ContinuousClock())

  public init<Source: Clock<Duration> & Sendable>(_ clock: Source) where Source.Instant == ContinuousClock.Instant {
    sleep = { try await clock.sleep(for: $0) }
    now = { clock.now }
  }
}
