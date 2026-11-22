import Foundation

public enum AnalyticsEventName: String, Sendable, CaseIterable {
  case appOpened = "app opened"
  case chatCreated = "chat created"
  case messageSent = "message sent"
  case modelSelected = "model selected"
  case harnessSelected = "harness selected"
  case turnCompleted = "turn completed"
  case turnFailed = "turn failed"
  case firstLaunchStarted = "first launch started"
  case firstLaunchStep = "first launch step"
  case firstLaunchFinished = "first launch finished"
  case claudeCodeLoginAnswered = "claude code login answered"
  case folderAccessAnswered = "folder access answered"
  case harnessSignInStarted = "harness sign in started"
  case harnessSignInFinished = "harness sign in finished"
  case permissionRequested = "permission requested"
  case permissionGranted = "permission granted"
  case setupRequestAnswered = "setup request answered"
  case gitSetup = "git setup"
  case projectAdded = "project added"
}

public enum AnalyticsPropertyValue: Sendable, Equatable {
  case string(String)
  case integer(Int)
  case double(Double)
  case boolean(Bool)
}

@MainActor
public protocol AnalyticsSink: AnyObject {
  func setEnabled(_ enabled: Bool)
  func setContext(_ context: TelemetryContext)
  func capture(_ event: AnalyticsEventName, properties: [String: AnalyticsPropertyValue])
}

@MainActor
public enum Analytics {
  public static var sink: (any AnalyticsSink)?

  public static func setEnabled(_ enabled: Bool) {
    sink?.setEnabled(enabled)
  }

  public static func setContext(_ context: TelemetryContext) {
    sink?.setContext(context)
  }

  public static func capture(
    _ event: AnalyticsEventName,
    properties: [String: AnalyticsPropertyValue] = [:]
  ) {
    sink?.capture(event, properties: properties)
  }

  public static func tokenBucket(_ value: UInt64?) -> String? {
    guard let value else { return nil }
    return switch value {
    case 0: "0"
    case 1..<1_000: "1-999"
    case 1_000..<10_000: "1k-9.9k"
    case 10_000..<100_000: "10k-99.9k"
    default: "100k+"
    }
  }
}
