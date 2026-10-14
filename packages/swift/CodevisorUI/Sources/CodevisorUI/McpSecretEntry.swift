import Foundation

public struct McpSecretEntry: Identifiable {
  public let id = UUID()
  public var name: String
  public var value: String
  public let existing: Bool

  public init(name: String, value: String, existing: Bool) {
    self.name = name
    self.value = value
    self.existing = existing
  }
}
