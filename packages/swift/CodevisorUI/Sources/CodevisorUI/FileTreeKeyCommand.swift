import SwiftUI

public enum FileTreeKeyCommand: Equatable, Sendable {
  case move(by: Int, extending: Bool)
  case expand
  case collapse
  case selectParent
  case open
  case preview
  case rename
  case delete
  case selectAll
  case copy
  case typeSelect(String)

  public static func command(
    key: KeyEquivalent, modifiers: EventModifiers, characters: String
  ) -> FileTreeKeyCommand? {
    if modifiers.contains(.command) { return commandShortcut(key: key, modifiers: modifiers) }
    if let navigation = navigation(key: key, extending: modifiers.contains(.shift)) { return navigation }
    return typing(characters, modifiers: modifiers)
  }

  private static func commandShortcut(key: KeyEquivalent, modifiers: EventModifiers) -> FileTreeKeyCommand? {
    switch key {
    case .upArrow: .selectParent
    case .downArrow, "o": .open
    case .delete, .deleteForward, KeyEquivalent("\u{7F}"): .delete
    case "a" where !modifiers.contains(.shift): .selectAll
    case "c" where !modifiers.contains(.shift): .copy
    default: nil
    }
  }

  private static func navigation(key: KeyEquivalent, extending: Bool) -> FileTreeKeyCommand? {
    switch key {
    case .upArrow: .move(by: -1, extending: extending)
    case .downArrow: .move(by: 1, extending: extending)
    case .rightArrow: .expand
    case .leftArrow: .collapse
    case .return: .rename
    case .space: .preview
    default: nil
    }
  }

  private static func typing(_ characters: String, modifiers: EventModifiers) -> FileTreeKeyCommand? {
    let isPlainTyping = modifiers.isDisjoint(with: [.control, .option])
    let printable = characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    guard isPlainTyping, printable, !characters.isEmpty else { return nil }
    return .typeSelect(characters)
  }
}
