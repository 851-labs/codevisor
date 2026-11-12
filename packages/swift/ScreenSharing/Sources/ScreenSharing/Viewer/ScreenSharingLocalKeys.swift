#if os(macOS)
  import CoreGraphics

  struct ScreenSharingLocalKeys: Sendable {
    private static let followUpKeys: Set<UInt16> = [53, 49, 36, 76]
    private static let commandModifiers = CGEventFlags([.maskCommand, .maskControl, .maskAlternate]).rawValue

    var shortcuts: Set<ScreenSharingShortcut> = []
    private(set) var localShortcutActive = false
    private var heldLocally: Set<UInt16> = []

    mutating func keepsLocal(keyCode: UInt16, down: Bool, modifiers: UInt64) -> Bool {
      guard down else { return heldLocally.remove(keyCode) != nil }
      guard heldLocally.contains(keyCode) || isShortcut(keyCode, modifiers) || isFollowUp(keyCode, modifiers) else {
        return false
      }

      heldLocally.insert(keyCode)
      localShortcutActive = true
      return true
    }

    mutating func reset() {
      heldLocally = []
      localShortcutActive = false
    }

    private func isShortcut(_ keyCode: UInt16, _ modifiers: UInt64) -> Bool {
      shortcuts.contains(.init(keyCode: keyCode, modifiers: modifiers))
    }

    private func isFollowUp(_ keyCode: UInt16, _ modifiers: UInt64) -> Bool {
      localShortcutActive && Self.followUpKeys.contains(keyCode) && modifiers & Self.commandModifiers == 0
    }
  }
#endif
