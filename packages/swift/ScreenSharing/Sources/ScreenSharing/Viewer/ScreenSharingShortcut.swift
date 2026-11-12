#if os(macOS)
  import CoreGraphics

  struct ScreenSharingShortcut: Hashable, Sendable {
    static let modifierMask = CGEventFlags([.maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue

    let keyCode: UInt16
    let modifiers: UInt64

    init(keyCode: UInt16, modifiers: UInt64) {
      self.keyCode = keyCode
      self.modifiers = modifiers & Self.modifierMask
    }

    init(keyCode: UInt16, _ modifiers: CGEventFlags) {
      self.init(keyCode: keyCode, modifiers: modifiers.rawValue)
    }
  }
#endif
