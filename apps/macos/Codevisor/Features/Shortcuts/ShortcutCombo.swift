import AppKit
import SwiftUI

/// The non-modifier half of a shortcut.
///
/// Characters are stored lowercase and matched against
/// `charactersIgnoringModifiers`; arrows are matched against
/// `NSEvent.specialKey`, and Escape/Return against their key codes — the three
/// ways AppKit actually reports these keys.
enum ShortcutKey: Equatable, Hashable, Sendable {
  case character(Character)
  case leftArrow
  case rightArrow
  case upArrow
  case downArrow
  case escape
  case `return`

  /// The SwiftUI equivalent, for `.keyboardShortcut(_:modifiers:)`.
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

  /// The glyph shown in menus and the Shortcuts settings list.
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

  /// The spelled-out name VoiceOver reads, e.g. "J" or "Left Arrow".
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

  /// Whether `event`'s key — modifiers aside — is this one.
  func matches(_ event: NSEvent) -> Bool {
    switch self {
    case .leftArrow: return event.specialKey == .leftArrow
    case .rightArrow: return event.specialKey == .rightArrow
    case .upArrow: return event.specialKey == .upArrow
    case .downArrow: return event.specialKey == .downArrow
    // The same key codes `SubmittingTextView` and the question picker
    // match: 53 = Escape, 36 = Return, 76 = keypad Enter.
    case .escape: return event.keyCode == 53
    case .return: return event.keyCode == 36 || event.keyCode == 76
    case let .character(character):
      guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
        return false
      }
      if characters == String(character) { return true }
      // AppKit keeps Shift applied in `charactersIgnoringModifiers` for
      // punctuation and digits, so ⇧⌘[ arrives as "{" and ⇧⌘7 as "&".
      return characters == Self.shiftedAliases[character].map(String.init)
    }
  }

  /// US-layout shifted forms of the keys a shortcut can use.
  private static let shiftedAliases: [Character: Character] = [
    "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^",
    "7": "&", "8": "*", "9": "(", "0": ")", "-": "_", "=": "+",
    "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"",
    ",": "<", ".": ">", "/": "?",
  ]
}

/// A key plus its modifiers: one bindable shortcut.
///
/// This is the single representation the whole app uses — SwiftUI menus render
/// it through `keyboardShortcut`, the AppKit key-equivalent paths match raw
/// events through `matches(_:)`, and the Settings ▸ Shortcuts list renders
/// `displayString`. Keeping all three off one value is what stops the menu, the
/// terminal handler, and the documentation from drifting apart.
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

  /// e.g. "⇧⌘[", "⌥⌘←". Modifier order follows the macOS HIG: ⌃⌥⇧⌘.
  var displayString: String {
    var result = ""
    if modifiers.contains(.control) { result += "⌃" }
    if modifiers.contains(.option) { result += "⌥" }
    if modifiers.contains(.shift) { result += "⇧" }
    if modifiers.contains(.command) { result += "⌘" }
    return result + key.displaySymbol
  }

  /// e.g. "Command-J" — the form VoiceOver reads naturally.
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

  /// Whether `event` is exactly this shortcut.
  ///
  /// Modifiers must match exactly, so ⌘[ never fires on ⇧⌘[. Arrow keys carry
  /// implicit `.function`/`.numericPad` flags — stripped here, or the
  /// comparison could never match.
  func matches(_ event: NSEvent) -> Bool {
    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.function, .numericPad])
    guard modifierFlags == eventModifierFlags else { return false }
    return key.matches(event)
  }
}
