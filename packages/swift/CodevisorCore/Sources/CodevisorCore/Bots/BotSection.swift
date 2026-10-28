import Foundation

public struct BotSection: Identifiable, Hashable, Sendable {
  public let id: UUID
  public var name: String
  public var position: String

  public init(id: UUID, name: String, position: String) {
    self.id = id
    self.name = name
    self.position = position
  }

  public static func precedes(_ lhs: BotSection, _ rhs: BotSection) -> Bool {
    lhs.position != rhs.position ? lhs.position < rhs.position : lhs.id.uuidString < rhs.id.uuidString
  }
}
