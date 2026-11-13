import Foundation

public enum ArchivedChatRetention: String, CaseIterable, Identifiable, Sendable {
  case sevenDays = "7-days"
  case thirtyDays = "30-days"
  case ninetyDays = "90-days"
  case never

  public static let standard: ArchivedChatRetention = .thirtyDays

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .sevenDays: "After 7 days"
    case .thirtyDays: "After 30 days"
    case .ninetyDays: "After 90 days"
    case .never: "Never"
    }
  }
}
