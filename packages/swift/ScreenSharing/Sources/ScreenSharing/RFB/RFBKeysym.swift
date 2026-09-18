import Foundation

/// X11 keysyms the KeyEvent message carries. Latin-1 characters are their own
/// keysym; any other Unicode scalar is 0x01000000 + its value (the X.Org
/// convention every modern server understands).
public enum RFBKeysym {
  public static let backSpace: UInt32 = 0xff08
  public static let tab: UInt32 = 0xff09
  public static let `return`: UInt32 = 0xff0d
  public static let escape: UInt32 = 0xff1b
  public static let insert: UInt32 = 0xff63
  public static let delete: UInt32 = 0xffff
  public static let home: UInt32 = 0xff50
  public static let left: UInt32 = 0xff51
  public static let up: UInt32 = 0xff52
  public static let right: UInt32 = 0xff53
  public static let down: UInt32 = 0xff54
  public static let pageUp: UInt32 = 0xff55
  public static let pageDown: UInt32 = 0xff56
  public static let end: UInt32 = 0xff57
  public static let keypadEnter: UInt32 = 0xff8d
  public static let shiftLeft: UInt32 = 0xffe1
  public static let shiftRight: UInt32 = 0xffe2
  public static let controlLeft: UInt32 = 0xffe3
  public static let controlRight: UInt32 = 0xffe4
  public static let capsLock: UInt32 = 0xffe5
  public static let metaLeft: UInt32 = 0xffe7
  public static let metaRight: UInt32 = 0xffe8
  public static let altLeft: UInt32 = 0xffe9
  public static let altRight: UInt32 = 0xffea
  public static let superLeft: UInt32 = 0xffeb
  public static let superRight: UInt32 = 0xffec
  public static func function(_ number: Int) -> UInt32 { 0xffbe + UInt32(number - 1) }

  public static func keysym(for scalar: Unicode.Scalar) -> UInt32 {
    switch scalar.value {
    case 0x08: backSpace
    case 0x09: tab
    case 0x0a, 0x0d: `return`
    case 0x1b: escape
    case 0x7f: delete
    case 0x20...0xff: scalar.value
    case let value where value < 0x20: value + 0x40  // control characters: the letter, the server applies Control
    case let value: 0x0100_0000 | value
    }
  }
}
