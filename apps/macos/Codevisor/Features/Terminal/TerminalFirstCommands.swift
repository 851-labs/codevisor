import Foundation

final class TerminalFirstCommands {
  static let shared = TerminalFirstCommands()

  private var commands: [UUID: String] = [:]

  func set(_ command: String, forPane id: UUID) {
    commands[id] = command
  }

  func take(forPane id: UUID) -> String? {
    commands.removeValue(forKey: id)
  }
}
