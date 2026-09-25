import Foundation

/// How often a host restarts a capture that ScreenCaptureKit stopped with an
/// error, instead of ending the session (851-2375): after `delay`, and at most
/// `limit` times in any `window`; past that the error ends the session, since
/// something keeps killing the stream.
struct ScreenSharingCaptureRestartPolicy {
  static let delay: Duration = .seconds(1)
  static let limit = 3
  static let window: TimeInterval = 60

  private var restarts: [TimeInterval] = []

  /// Records a restart at `now` and returns true, or returns false when the budget is spent.
  mutating func allowsRestart(now: TimeInterval) -> Bool {
    restarts.removeAll { now - $0 >= Self.window }
    guard restarts.count < Self.limit else { return false }
    restarts.append(now)
    return true
  }
}
