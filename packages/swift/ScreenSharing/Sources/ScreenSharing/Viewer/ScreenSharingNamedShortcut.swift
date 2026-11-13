#if os(macOS)
  import CoreGraphics

  struct ScreenSharingNamedShortcut {
    private static let modifierSymbols: [(CGEventFlags, String)] = [
      (.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘"),
    ]
    private static let keyNames: [UInt16: String] = [
      36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
      123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
      98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    let character: Character?
    let shortcut: ScreenSharingShortcut

    init(character: Character?, shortcut: ScreenSharingShortcut) {
      self.character = character
      self.shortcut = shortcut
    }

    init(_ character: Character, keyCode: UInt16, _ modifiers: CGEventFlags) {
      self.init(character: character, shortcut: .init(keyCode: keyCode, modifiers))
    }

    var name: String? {
      guard let key = Self.keyNames[shortcut.keyCode] ?? typedKey else { return nil }
      return modifiers + key
    }

    private var typedKey: String? {
      guard let character, character.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }) else { return nil }
      return String(character).uppercased()
    }

    private var modifiers: String {
      Self.modifierSymbols.filter { shortcut.modifiers & $0.0.rawValue != 0 }.map(\.1).joined()
    }
  }
#endif
