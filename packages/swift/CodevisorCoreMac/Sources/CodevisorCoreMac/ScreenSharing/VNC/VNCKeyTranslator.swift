import Carbon.HIToolbox
import CodevisorScreenSharing
import Foundation
import ScreenSharingRFB

/// Mac virtual key codes (what `ScreenSharingInputEvent.key` carries) to X11
/// keysyms. Modifier and navigation keys map by table; everything else goes
/// through the current keyboard layout with Shift, Option and Caps Lock
/// applied — never Control or Command, so ⌘C reaches the server as Super+c,
/// which is what it expects.
struct VNCKeyTranslator: Sendable {
  typealias Layout = @Sendable (_ code: UInt16, _ carbonModifiers: UInt32) -> Unicode.Scalar?

  static let modifierKeysyms: [UInt16: UInt32] = [
    56: RFBKeysym.shiftLeft, 60: RFBKeysym.shiftRight, 59: RFBKeysym.controlLeft, 62: RFBKeysym.controlRight,
    58: RFBKeysym.altLeft, 61: RFBKeysym.altRight, 55: RFBKeysym.superLeft, 54: RFBKeysym.superRight,
    57: RFBKeysym.capsLock,
  ]
  static let specialKeysyms: [UInt16: UInt32] = [
    36: RFBKeysym.return, 76: RFBKeysym.keypadEnter, 48: RFBKeysym.tab, 51: RFBKeysym.backSpace,
    53: RFBKeysym.escape, 117: RFBKeysym.delete, 114: RFBKeysym.insert, 115: RFBKeysym.home, 119: RFBKeysym.end,
    116: RFBKeysym.pageUp, 121: RFBKeysym.pageDown, 123: RFBKeysym.left, 124: RFBKeysym.right,
    125: RFBKeysym.down, 126: RFBKeysym.up,
    122: RFBKeysym.function(1), 120: RFBKeysym.function(2), 99: RFBKeysym.function(3), 118: RFBKeysym.function(4),
    96: RFBKeysym.function(5), 97: RFBKeysym.function(6), 98: RFBKeysym.function(7), 100: RFBKeysym.function(8),
    101: RFBKeysym.function(9), 109: RFBKeysym.function(10), 103: RFBKeysym.function(11), 111: RFBKeysym.function(12),
  ]
  /// The Fn key has no keysym; it is dropped.
  static let ignoredCodes: Set<UInt16> = [63]

  private let layout: Layout

  init(layout: @escaping Layout = VNCKeyTranslator.currentLayout) { self.layout = layout }

  /// nil: nothing to send for this key.
  func keysym(code: UInt16, modifiers: UInt8) -> UInt32? {
    if Self.ignoredCodes.contains(code) { return nil }
    if let keysym = Self.modifierKeysyms[code] ?? Self.specialKeysyms[code] { return keysym }
    // Carbon modifier state as UCKeyTranslate wants it: (flags >> 8) & 0xff.
    var carbon: UInt32 = 0
    if modifiers & 1 != 0 { carbon |= UInt32(shiftKey >> 8) }
    if modifiers & 4 != 0 { carbon |= UInt32(optionKey >> 8) }
    if modifiers & 16 != 0 { carbon |= UInt32(alphaLock >> 8) }
    guard let scalar = layout(code, carbon) else { return nil }
    return RFBKeysym.keysym(for: scalar)
  }

  /// The user's current keyboard layout through `UCKeyTranslate`.
  static let currentLayout: Layout = { code, carbonModifiers in
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    return data.withUnsafeBytes { bytes -> Unicode.Scalar? in
      guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
      var deadKeys: UInt32 = 0
      var length = 0
      var characters = [UniChar](repeating: 0, count: 4)
      let status = UCKeyTranslate(
        layout, code, UInt16(kUCKeyActionDown), carbonModifiers, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length, &characters)
      guard status == noErr, length > 0 else { return nil }
      return String(utf16CodeUnits: characters, count: length).unicodeScalars.first
    }
  }
}
