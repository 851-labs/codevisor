import AppKit
import ApplicationServices
import Foundation

func computerUseModifierFlag(named name: String) -> CGEventFlags? {
  switch name.lowercased() {
  case "cmd", "command", "meta", "super": .maskCommand
  case "ctrl", "control": .maskControl
  case "option", "alt": .maskAlternate
  case "shift": .maskShift
  default: nil
  }
}

extension ComputerUseBridge {
  func keyPress(_ value: String, pid: pid_t, global: Bool = false) throws {
    let names: [String: CGKeyCode] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
      "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
      "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
      "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
      "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
      "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
      "n": 45, "m": 46, ".": 47,
      "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
      "backspace": 51, "forwarddelete": 117, "home": 115, "end": 119,
      "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
      "pageup": 116, "pagedown": 121,
    ]
    let parts = value.split(separator: "+").map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let rawKey = parts.last, !rawKey.isEmpty else {
      throw BridgeError("Unsupported key: \(value)")
    }
    var flags: CGEventFlags = []
    for modifier in parts.dropLast() {
      guard let flag = computerUseModifierFlag(named: modifier) else {
        throw BridgeError("Unsupported key modifier: \(modifier)")
      }
      flags.insert(flag)
    }
    if rawKey.count == 1, rawKey.uppercased() == rawKey, rawKey.lowercased() != rawKey {
      flags.insert(.maskShift)
    }
    let normalized = rawKey.lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
    guard let code = names[normalized] ?? names[rawKey.lowercased()] else {
      if flags.isEmpty, rawKey.count == 1 {
        return try typeText(rawKey, pid: pid, global: global)
      }
      throw BridgeError("Unsupported key: \(value)")
    }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    else { throw BridgeError("Unable to create keyboard event") }
    down.flags = flags
    up.flags = flags
    postKeyboardEvent(down, pid: pid, global: global)
    postKeyboardEvent(up, pid: pid, global: global)
  }

  func typeText(_ text: String, pid: pid_t, global: Bool = false) throws {
    for character in text {
      if character == "\n" || character == "\r" {
        try postKeyCode(36, pid: pid, global: global)
        continue
      }
      if character == "\t" {
        try postKeyCode(48, pid: pid, global: global)
        continue
      }
      if character == "\u{8}" || character == "\u{7f}" {
        try postKeyCode(51, pid: pid, global: global)
        continue
      }
      guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
      else { throw BridgeError("Unable to create keyboard event") }
      let units = Array(String(character).utf16)
      units.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
      }
      postKeyboardEvent(down, pid: pid, global: global)
      postKeyboardEvent(up, pid: pid, global: global)
    }
  }

  private func postKeyCode(_ code: CGKeyCode, pid: pid_t, global: Bool) throws {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    else { throw BridgeError("Unable to create keyboard event") }
    postKeyboardEvent(down, pid: pid, global: global)
    postKeyboardEvent(up, pid: pid, global: global)
  }

  private func postKeyboardEvent(_ event: CGEvent, pid: pid_t, global: Bool) {
    if global { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
  }
}
