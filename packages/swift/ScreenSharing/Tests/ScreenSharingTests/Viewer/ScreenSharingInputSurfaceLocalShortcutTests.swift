import AppKit
import Testing
@testable import ScreenSharing

@MainActor
struct ScreenSharingInputSurfaceLocalShortcutTests {
  @Test func theTapGetsTheScreenshotShortcutsFromSystemSettingsOnlyWhileTheSettingIsOn() throws {
    let optionCommand: CGEventFlags = [.maskAlternate, .maskCommand]
    let fixture = try InputSurfaceFixture(symbolicHotKeys: [
      "30": ["enabled": true, "value": ["parameters": [115, 1, Int(optionCommand.rawValue)], "type": "standard"]]
    ])
    defer { fixture.close() }
    #expect(fixture.keyboard.localShortcuts.isEmpty)
    fixture.input.localShortcuts = [.screenshots]
    #expect(fixture.keyboard.localShortcuts.contains(.init(keyCode: 1, optionCommand)))
    #expect(!fixture.keyboard.localShortcuts.contains(.init(keyCode: 21, [.maskShift, .maskCommand])))
    #expect(fixture.keyboard.localShortcuts.contains(.init(keyCode: 20, [.maskShift, .maskCommand])))
    fixture.input.localShortcuts = []
    #expect(fixture.keyboard.localShortcuts.isEmpty)
  }

  @Test func aKeyOrClickReachingTheVideoTakesTheKeyboardBackFromALocalShortcut() throws {
    let fixture = try InputSurfaceFixture()
    defer { fixture.close() }
    #expect(fixture.input.route(try fixture.key(.keyDown, code: 53)) == nil)
    #expect(fixture.keyboard.reclaims == 1)
    #expect(fixture.events == [.key(code: 53, down: true, repeatKey: false, modifiers: 0)])
    _ = fixture.input.route(try fixture.mouse(.leftMouseDown, at: .init(x: 100, y: 100)))
    #expect(fixture.keyboard.reclaims == 2)
  }
}
