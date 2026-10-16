import Foundation
import ScreenSharing

public struct ScreenSharingModifiers: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  public static let shift = ScreenSharingModifiers(rawValue: 1)
  public static let control = ScreenSharingModifiers(rawValue: 2)
  public static let option = ScreenSharingModifiers(rawValue: 4)
  public static let command = ScreenSharingModifiers(rawValue: 8)

  static let ordered: [(ScreenSharingModifiers, UInt16)] = [
    (.command, 55), (.shift, 56), (.option, 58), (.control, 59),
  ]
}

public enum ScreenSharingKey: UInt16, Sendable {
  case returnKey = 36
  case tab = 48
  case space = 49
  case delete = 51
  case escape = 53
  case forwardDelete = 117
  case left = 123
  case right = 124
  case down = 125
  case up = 126
}

enum ScreenSharingKeyboard {
  static func press(code: UInt16, modifiers: ScreenSharingModifiers) -> [ScreenSharingInputEvent] {
    var held: ScreenSharingModifiers = []
    var events: [ScreenSharingInputEvent] = []
    for (modifier, key) in ScreenSharingModifiers.ordered where modifiers.contains(modifier) {
      held.insert(modifier)
      events.append(.key(code: key, down: true, repeatKey: false, modifiers: held.rawValue))
    }
    events.append(.key(code: code, down: true, repeatKey: false, modifiers: held.rawValue))
    events.append(.key(code: code, down: false, repeatKey: false, modifiers: held.rawValue))
    for (modifier, key) in ScreenSharingModifiers.ordered.reversed() where modifiers.contains(modifier) {
      held.remove(modifier)
      events.append(.key(code: key, down: false, repeatKey: false, modifiers: held.rawValue))
    }
    return events
  }

  static func type(_ text: String, modifiers: ScreenSharingModifiers) -> [ScreenSharingInputEvent] {
    var events: [ScreenSharingInputEvent] = []
    var unmapped = ""
    func flush() {
      guard !unmapped.isEmpty else { return }
      events.append(.text(unmapped))
      unmapped = ""
    }
    for character in text {
      if let (code, shifted) = key(for: character) {
        flush()
        events += press(code: code, modifiers: shifted ? modifiers.union(.shift) : modifiers)
      } else if modifiers.isEmpty {
        unmapped.append(character)
        if unmapped.utf16.count >= 512 { flush() }
      }
    }
    flush()
    return events
  }

  static func key(for character: Character) -> (code: UInt16, shifted: Bool)? {
    if let code = unshifted[character] { return (code, false) }
    if let code = shifted[character] { return (code, true) }
    guard character.isASCII, character.isUppercase, let lower = character.lowercased().first,
      let code = unshifted[lower]
    else { return nil }
    return (code, true)
  }

  static func code(forHIDUsage usage: Int) -> UInt16? { hid[usage] }

  private static let unshifted: [Character: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\n": 36, "l": 37,
    "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49,
    "`": 50,
  ]

  private static let shifted: [Character: UInt16] = [
    "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "+": 24, "(": 25, "&": 26, "_": 27, "*": 28, ")": 29,
    "}": 30, "{": 33, "\"": 39, ":": 41, "|": 42, "<": 43, "?": 44, ">": 47, "~": 50,
  ]

  private static let hid: [Int: UInt16] = {
    let letters: [UInt16] = [
      0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
    ]
    var table = Dictionary(uniqueKeysWithValues: letters.enumerated().map { (4 + $0.offset, $0.element) })
    let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    for (offset, code) in digits.enumerated() { table[30 + offset] = code }
    let rest: [Int: UInt16] = [
      40: 36, 41: 53, 42: 51, 43: 48, 44: 49, 45: 27, 46: 24, 47: 33, 48: 30, 49: 42, 51: 41, 52: 39, 53: 50, 54: 43,
      55: 47, 56: 44, 58: 122, 59: 120, 60: 99, 61: 118, 62: 96, 63: 97, 64: 98, 65: 100, 66: 101, 67: 109, 68: 103,
      69: 111, 74: 115, 75: 116, 76: 117, 77: 119, 78: 121, 79: 124, 80: 123, 81: 125, 82: 126,
    ]
    table.merge(rest) { $1 }
    return table
  }()
}
