import CodevisorCore
import Foundation
import Testing
@testable import CodevisorCoreMac

struct ScreenSharingMachineSettingsTests {
  static let original = ScreenSharingMachineSettings(
    name: "tuftlord", connection: "VNC", address: "tuftlord.local:5900", dynamicResolution: true,
    displays: [.init(id: "a", name: "Built-in"), .init(id: "b", name: "Studio Display")], preferredDisplayId: "a")

  @Test func anUntouchedDraftChangesNothing() {
    let changes = ScreenSharingMachineSettingsDraft(Self.original).changes(from: Self.original)
    #expect(changes.isEmpty && !changes.reconnects)
  }

  @Test func dynamicResolutionAppliesWithoutReconnecting() {
    var draft = ScreenSharingMachineSettingsDraft(Self.original)
    draft.settings.dynamicResolution = false
    let changes = draft.changes(from: Self.original)
    #expect(changes == .init(dynamicResolution: false))
    #expect(!changes.reconnects)
  }

  @Test func anotherDisplayReconnectsButOnlyToADisplayTheMachineHas() {
    var draft = ScreenSharingMachineSettingsDraft(Self.original)
    draft.settings.preferredDisplayId = "b"
    #expect(draft.changes(from: Self.original) == .init(preferredDisplayId: "b"))
    #expect(draft.changes(from: Self.original).reconnects)
    draft.settings.preferredDisplayId = "gone"
    #expect(draft.changes(from: Self.original).isEmpty)
  }

  @Test func hdrChangesApplyWithoutReconnecting() {
    var withHDR = Self.original
    withHDR.highDynamicRange = false
    var draft = ScreenSharingMachineSettingsDraft(withHDR)
    draft.settings.highDynamicRange = true
    #expect(draft.changes(from: withHDR) == .init(highDynamicRange: true))
    #expect(!draft.changes(from: withHDR).reconnects)
  }

  @Test func soundChangesApplyWithoutReconnecting() {
    var withSound = Self.original
    withSound.sound = .init(enabled: true, volume: 1)
    var draft = ScreenSharingMachineSettingsDraft(withSound)
    draft.settings.sound?.volume = 0.4
    #expect(draft.changes(from: withSound) == .init(sound: .init(enabled: true, volume: 0.4)))
    #expect(!draft.changes(from: withSound).reconnects)
    draft.settings.sound = .init(enabled: true, volume: 1)
    #expect(draft.changes(from: withSound).isEmpty)
    #expect(ScreenSharingMachineSettingsDraft(Self.original).changes(from: Self.original).sound == nil)
  }

  @Test func dynamicResolutionMentionsMirroringOnlyForHostsThatMirrorTheirDisplay() {
    var settings = Self.original
    #expect(!settings.dynamicResolutionExplanation.contains("mirrors"), "a VNC desktop has no display of its own")
    settings.dynamicResolutionMirrorsDisplay = true
    #expect(
      settings.dynamicResolutionExplanation.hasSuffix("While you're connected, its own display mirrors the new size."))
  }

  @Test func turningOffLocalScreenshotsAppliesWithoutReconnectingAndSendsThemToTheHost() {
    var withKeyboard = Self.original
    withKeyboard.keyboard = .init()
    #expect(withKeyboard.keyboard?.localShortcuts == [.screenshots], "screenshots stay on this Mac by default")
    var draft = ScreenSharingMachineSettingsDraft(withKeyboard)
    draft.settings.keyboard?.screenshotsStayLocal = false
    let changes = draft.changes(from: withKeyboard)
    #expect(changes == .init(keyboard: .init(screenshotsStayLocal: false)))
    #expect(changes.keyboard?.localShortcuts == [])
    #expect(!changes.reconnects)
  }

  @Test func theKeyboardFooterListsTheShortcutsKeptOnThisMacAndNeverNamesTheMachine() {
    var settings = Self.original
    settings.screenshotShortcuts = ["⇧⌘3", "⇧⌘4", "⇧⌘5"]
    #expect(settings.screenshotsExplanation == "⇧⌘3, ⇧⌘4 and ⇧⌘5 aren't sent to the remote machine.")
    #expect(!settings.screenshotsExplanation.contains(settings.name))
    settings.screenshotShortcuts = ["⇧⌘3", "⌥⌘S"]
    #expect(settings.screenshotsExplanation == "⇧⌘3 and ⌥⌘S aren't sent to the remote machine.")
    settings.screenshotShortcuts = ["⇧⌘5"]
    #expect(settings.screenshotsExplanation == "⇧⌘5 isn't sent to the remote machine.")
  }
}
