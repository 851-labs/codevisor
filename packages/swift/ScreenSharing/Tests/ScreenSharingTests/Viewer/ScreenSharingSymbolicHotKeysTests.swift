import AppKit
import Testing

@testable import ScreenSharing

struct ScreenSharingSymbolicHotKeysTests {
  static let shiftCommand: CGEventFlags = [.maskShift, .maskCommand]
  static let controlShiftCommand: CGEventFlags = [.maskControl, .maskShift, .maskCommand]
  static let optionCommand: CGEventFlags = [.maskAlternate, .maskCommand]
  static let standard: Set<ScreenSharingShortcut> = [
    .init(keyCode: 20, shiftCommand), .init(keyCode: 20, controlShiftCommand),
    .init(keyCode: 21, shiftCommand), .init(keyCode: 21, controlShiftCommand),
    .init(keyCode: 23, shiftCommand),
    .init(keyCode: 22, shiftCommand), .init(keyCode: 22, controlShiftCommand),
  ]

  static var leftByCleanShot: [String: Any] {
    [
      "28": entry(enabled: false, parameters: [51, 20, 1_179_648]),
      "29": entry(enabled: false, parameters: [51, 20, 1_441_792]),
      "30": entry(enabled: false, parameters: [52, 21, 1_179_648]),
      "31": entry(enabled: false, parameters: [52, 21, 1_441_792]),
      "184": entry(enabled: false, parameters: [53, 23, 1_179_648]),
    ]
  }

  @Test func withNothingChangedInSystemSettingsTheStandardScreenshotShortcutsStayLocal() {
    #expect(ScreenSharingSymbolicHotKeys.shortcuts(for: [.screenshots], in: nil) == Self.standard)
    #expect(ScreenSharingSymbolicHotKeys.shortcuts(for: [.screenshots], in: [:]) == Self.standard)
    #expect(ScreenSharingSymbolicHotKeys.shortcuts(for: [], in: nil).isEmpty)
  }

  @Test func shortcutsMacOSTurnedOffForAnotherScreenshotAppStillStayLocal() {
    #expect(ScreenSharingSymbolicHotKeys.shortcuts(for: [.screenshots], in: Self.leftByCleanShot) == Self.standard)
  }

  @Test func remappedShortcutsReplaceTheStandardOnesWhetherTurnedOnOrOff() {
    let hotKeys: [String: Any] = [
      "30": Self.entry(enabled: true, parameters: [65535, 1, Int(Self.optionCommand.rawValue)]),
      "28": Self.entry(enabled: false, parameters: [65535, 2, Int(Self.optionCommand.rawValue)]),
      "184": Self.entry(enabled: false, parameters: [65535, 65535, 0]),
      "31": ["enabled": true],
      "29": "unreadable",
    ]
    let shortcuts = ScreenSharingSymbolicHotKeys.shortcuts(for: [.screenshots], in: hotKeys)
    #expect(shortcuts.contains(.init(keyCode: 1, Self.optionCommand)), "⌥⌘S replaces ⇧⌘4")
    #expect(!shortcuts.contains(.init(keyCode: 21, Self.shiftCommand)))
    #expect(shortcuts.contains(.init(keyCode: 2, Self.optionCommand)), "a turned-off shortcut keeps its own combo")
    #expect(!shortcuts.contains(.init(keyCode: 20, Self.shiftCommand)))
    #expect(shortcuts.contains(.init(keyCode: 23, Self.shiftCommand)), "an entry with no key keeps its standard")
    #expect(
      shortcuts.contains(.init(keyCode: 21, Self.controlShiftCommand)), "an entry without a value keeps its standard")
    #expect(shortcuts.contains(.init(keyCode: 20, Self.controlShiftCommand)))
    #expect(shortcuts.count == 7)
  }

  @Test func theMainShortcutsAreNamedWithoutTheirCopyOrTouchBarVariants() {
    #expect(ScreenSharingSymbolicHotKeys.names(for: .screenshots, in: nil) == ["⇧⌘3", "⇧⌘4", "⇧⌘5"])
    #expect(
      ScreenSharingSymbolicHotKeys.names(for: .screenshots, in: Self.leftByCleanShot) == ["⇧⌘3", "⇧⌘4", "⇧⌘5"])
  }

  @Test func remappedShortcutsAreNamedByTheirOwnCombosInScreenshotOrder() {
    let command = Int(CGEventFlags.maskCommand.rawValue)
    var hotKeys: [String: Any] = [
      "30": Self.entry(enabled: true, parameters: [115, 1, Int(Self.optionCommand.rawValue)]),
      "184": Self.entry(enabled: false, parameters: [65535, 96, command | Int(CGEventFlags.maskSecondaryFn.rawValue)]),
      "29": Self.entry(enabled: true, parameters: [99, 8, Int(Self.controlShiftCommand.rawValue)]),
    ]
    #expect(ScreenSharingSymbolicHotKeys.names(for: .screenshots, in: hotKeys) == ["⇧⌘3", "⌥⌘S", "⌘F5"])
    hotKeys["184"] = hotKeys["30"]
    #expect(
      ScreenSharingSymbolicHotKeys.names(for: .screenshots, in: hotKeys) == ["⇧⌘3", "⌥⌘S"], "a shared combo is named once")
  }

  private static func entry(enabled: Bool, parameters: [Int]) -> [String: Any] {
    ["enabled": enabled, "value": ["type": "standard", "parameters": parameters]]
  }
}
