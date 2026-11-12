import AppKit
import Testing

@testable import ScreenSharing

struct ScreenSharingSymbolicHotKeysTests {
  static let shiftCommand: CGEventFlags = [.maskShift, .maskCommand]
  static let controlShiftCommand: CGEventFlags = [.maskControl, .maskShift, .maskCommand]

  @Test func withNothingChangedInSystemSettingsTheStandardScreenshotShortcutsStayLocal() {
    let shortcuts = ScreenSharingSymbolicHotKeys.shortcuts(for: [.screenshots], in: nil)
    #expect(
      shortcuts == [
        .init(keyCode: 20, Self.shiftCommand), .init(keyCode: 20, Self.controlShiftCommand),
        .init(keyCode: 21, Self.shiftCommand), .init(keyCode: 21, Self.controlShiftCommand),
        .init(keyCode: 23, Self.shiftCommand),
        .init(keyCode: 22, Self.shiftCommand), .init(keyCode: 22, Self.controlShiftCommand),
      ])
    #expect(ScreenSharingSymbolicHotKeys.shortcuts(for: [.screenshots], in: [:]) == shortcuts)
    #expect(ScreenSharingSymbolicHotKeys.shortcuts(for: [], in: nil).isEmpty)
  }

  @Test func remappedAndDisabledShortcutsFromSystemSettingsAreHonoured() {
    let hotKeys: [String: Any] = [
      "30": entry(enabled: true, parameters: [65535, 1, Int(CGEventFlags([.maskAlternate, .maskCommand]).rawValue)]),
      "28": entry(enabled: false, parameters: [51, 20, Int(Self.shiftCommand.rawValue)]),
      "184": entry(enabled: true, parameters: [65535, 65535, 0]),
      "31": ["enabled": true],
      "29": "unreadable",
    ]
    let shortcuts = ScreenSharingSymbolicHotKeys.shortcuts(for: [.screenshots], in: hotKeys)
    #expect(shortcuts.contains(.init(keyCode: 1, [.maskAlternate, .maskCommand])), "⌥⌘S replaces ⇧⌘4")
    #expect(!shortcuts.contains(.init(keyCode: 21, Self.shiftCommand)))
    #expect(!shortcuts.contains(.init(keyCode: 20, Self.shiftCommand)), "a turned-off shortcut goes to the host")
    #expect(!shortcuts.contains(.init(keyCode: 23, Self.shiftCommand)), "a shortcut with no key is dropped")
    #expect(
      shortcuts.contains(.init(keyCode: 21, Self.controlShiftCommand)), "an entry without a key keeps its standard")
    #expect(shortcuts.contains(.init(keyCode: 20, Self.controlShiftCommand)))
    #expect(shortcuts.count == 5)
  }

  private func entry(enabled: Bool, parameters: [Int]) -> [String: Any] {
    ["enabled": enabled, "value": ["type": "standard", "parameters": parameters]]
  }
}
