import Foundation

enum StaleSend {
  static let limit: Duration = .seconds(10 * 60)
  static let reason =
    "This message waited more than 10 minutes for a connection, so it wasn't sent. Try Again sends it now."

  struct Error: LocalizedError {
    var errorDescription: String? { StaleSend.reason }
  }

  static func hasWaitedTooLong(since start: Date, now: Date) -> Bool {
    now.timeIntervalSince(start) > TimeInterval(limit.components.seconds)
  }
}
