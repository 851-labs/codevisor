import Foundation

/// One header or environment entry in the MCP editor. `existing` marks a
/// value the server already holds: it arrives name-only (secrets never come
/// back), so an untouched row must not be mistaken for a blank one.
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
