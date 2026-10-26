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
}
