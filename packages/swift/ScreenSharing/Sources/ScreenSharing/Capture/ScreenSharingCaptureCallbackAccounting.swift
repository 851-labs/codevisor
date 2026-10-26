import Foundation

public enum ScreenSharingCaptureCallbackAccounting {
  public enum Status: Int, CaseIterable, Sendable {
    case complete = 0, idle = 1, blank = 2, suspended = 3, started = 4, stopped = 5

    public var counterName: String {
      switch self {
      case .complete: "captureCallbacksComplete"
      case .idle: "captureCallbacksIdle"
      case .blank: "captureCallbacksBlank"
      case .suspended: "captureCallbacksSuspended"
      case .started: "captureCallbacksStarted"
      case .stopped: "captureCallbacksStopped"
      }
    }
  }

  public static let otherStatusCounter = "captureCallbacksOtherStatus"
  public static let invalidSampleCounter = "captureSamplesInvalid"
  public static let missingStatusCounter = "captureSamplesWithoutStatus"
  public static let missingImageCounter = "captureSamplesWithoutImage"
  public static let latestStatusLabel = "captureLatestStatus"

  public static func callbackTotal(counters: [String: Int]) -> Int {
    let buckets = Status.allCases.map(\.counterName) + [otherStatusCounter, invalidSampleCounter, missingStatusCounter]
    return buckets.reduce(0) { $0 + counters[$1, default: 0] }
  }

  @discardableResult
  public static func record(
    valid: Bool, rawStatus: Int?, hasImage: Bool, metrics: ScreenSharingMetrics
  ) -> Bool {
    guard valid else { metrics.increment(invalidSampleCounter); return false }
    guard let rawStatus else { metrics.increment(missingStatusCounter); return false }
    guard let status = Status(rawValue: rawStatus) else {
      metrics.increment(otherStatusCounter)
      metrics.label(latestStatusLabel, "other(\(rawStatus))")
      return false
    }
    metrics.increment(status.counterName)
    metrics.label(latestStatusLabel, String(describing: status))
    guard status == .complete else { return false }
    guard hasImage else { metrics.increment(missingImageCounter); return false }
    return true
  }
}
