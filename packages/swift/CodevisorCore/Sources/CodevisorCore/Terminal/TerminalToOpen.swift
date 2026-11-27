import Foundation

public struct TerminalToOpen: Equatable, Sendable {
  public var command: String
  public var name: String

  public init(command: String, name: String) {
    self.command = command
    self.name = name
  }
}
