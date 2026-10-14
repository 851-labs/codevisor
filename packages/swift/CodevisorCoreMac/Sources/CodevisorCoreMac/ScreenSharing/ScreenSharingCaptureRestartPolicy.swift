import Foundation

struct ScreenSharingCaptureRestartPolicy {
  static let delay: Duration = .seconds(1)
  static let limit = 3
  static let window: TimeInterval = 60

  private var restarts: [TimeInterval] = []

  mutating func allowsRestart(now: TimeInterval) -> Bool {
    restarts.removeAll { now - $0 >= Self.window }
    guard restarts.count < Self.limit else { return false }
    restarts.append(now)
    return true
  }
}
