import AppKit
import SwiftUI

enum ShortcutKey: Equatable, Hashable, Sendable {
  case character(Character)
  case leftArrow
  case rightArrow
  case upArrow
  case downArrow
  case escape
  case `return`

  var keyEquivalent: KeyEquivalent {
    switch self {
    case let .character(character): KeyEquivalent(character)
    case .leftArrow: .leftArrow
    case .rightArrow: .rightArrow
    case .upArrow: .upArrow
    case .downArrow: .downArrow
    case .escape: .escape
    case .return: .return
    }
  }

  var displaySymbol: String {
    switch self {
    case let .character(character): String(character).uppercased()
    case .leftArrow: "←"
    case .rightArrow: "→"
    case .upArrow: "↑"
    case .downArrow: "↓"
    case .escape: "⎋"
    case .return: "↩"
    }
  }

  var accessibilityName: String {
    switch self {
    case let .character(character): String(character).uppercased()
    case .leftArrow: "Left Arrow"
    case .rightArrow: "Right Arrow"
    case .upArrow: "Up Arrow"
    case .downArrow: "Down Arrow"
    case .escape: "Escape"
    case .return: "Return"
    }
  }

  func matches(_ event: NSEvent) -> Bool {
    switch self {
    case .leftArrow: return event.specialKey == .leftArrow
    case .rightArrow: return event.specialKey == .rightArrow
    case .upArrow: return event.specialKey == .upArrow
    case .downArrow: return event.specialKey == .downArrow
    case .escape: return event.keyCode == 53
    case .return: return event.keyCode == 36 || event.keyCode == 76
    case let .character(character):
      guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
        return false
      }
      if characters == String(character) { return true }
      return characters == Self.shiftedAliases[character].map(String.init)
    }
  }

  private static let shiftedAliases: [Character: Character] = [
    "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^",
    "7": "&", "8": "*", "9": "(", "0": ")", "-": "_", "=": "+",
    "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"",
    ",": "<", ".": ">", "/": "?",
  ]
}

struct ShortcutCombo: Equatable, Sendable {
  let key: ShortcutKey
  let modifiers: EventModifiers

  init(_ key: ShortcutKey, _ modifiers: EventModifiers = []) {
    self.key = key
    self.modifiers = modifiers
  }

  init(_ character: Character, _ modifiers: EventModifiers = []) {
    self.init(.character(character), modifiers)
  }

  var keyboardShortcut: KeyboardShortcut {
    KeyboardShortcut(key.keyEquivalent, modifiers: modifiers)
  }

  var displayString: String {
    var result = ""
    if modifiers.contains(.control) { result += "⌃" }
    if modifiers.contains(.option) { result += "⌥" }
    if modifiers.contains(.shift) { result += "⇧" }
    if modifiers.contains(.command) { result += "⌘" }
    return result + key.displaySymbol
  }

  var accessibilityDescription: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("Control") }
    if modifiers.contains(.option) { parts.append("Option") }
    if modifiers.contains(.shift) { parts.append("Shift") }
    if modifiers.contains(.command) { parts.append("Command") }
    parts.append(key.accessibilityName)
    return parts.joined(separator: "-")
  }

  var eventModifierFlags: NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if modifiers.contains(.command) { flags.insert(.command) }
    if modifiers.contains(.shift) { flags.insert(.shift) }
    if modifiers.contains(.option) { flags.insert(.option) }
    if modifiers.contains(.control) { flags.insert(.control) }
    return flags
  }

  func matches(_ event: NSEvent) -> Bool {
    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.function, .numericPad])
    guard modifierFlags == eventModifierFlags else { return false }
    return key.matches(event)
  }
}
