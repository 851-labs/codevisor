import Foundation

public enum AnalyticsEventName: String, Sendable, CaseIterable {
  case appOpened = "app opened"
  case chatCreated = "chat created"
  case messageSent = "message sent"
  case modelSelected = "model selected"
  case harnessSelected = "harness selected"
  case turnCompleted = "turn completed"
  case turnFailed = "turn failed"
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
  func capture(_ event: AnalyticsEventName, properties: [String: AnalyticsPropertyValue])
}

@MainActor
public enum Analytics {
  public static var sink: (any AnalyticsSink)?

  public static func setEnabled(_ enabled: Bool) {
    sink?.setEnabled(enabled)
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
