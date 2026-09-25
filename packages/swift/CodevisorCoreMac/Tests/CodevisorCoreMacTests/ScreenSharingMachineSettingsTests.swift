import Foundation
import Testing
@testable import CodevisorCoreMac

/// The machine settings sheet's edits (851-2367): only what changed is applied, and only a new
/// display or new sign-in needs a new connection.
struct ScreenSharingMachineSettingsTests {
  static let original = ScreenSharingMachineSettings(
    name: "tuftlord", connection: "VNC", address: "tuftlord.local:5900",
    signIn: .init(userName: "tuftlord", hasSavedPassword: true), dynamicResolution: true,
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

  /// Sound (851-2379) applies live, never reconnects, and only a connection with sound shows it.
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

  @Test func signInChangesReconnect() {
    var draft = ScreenSharingMachineSettingsDraft(Self.original)
    draft.settings.signIn?.userName = "  admin "
    #expect(draft.changes(from: Self.original) == .init(userName: "admin"))
    draft = ScreenSharingMachineSettingsDraft(Self.original)
    draft.changingPassword = true
    #expect(draft.changes(from: Self.original).isEmpty, "Change… with nothing typed keeps the saved one")
    draft.newPassword = "secret"
    #expect(draft.changes(from: Self.original) == .init(password: .replace("secret")))
    #expect(draft.changes(from: Self.original).reconnects)
    draft = ScreenSharingMachineSettingsDraft(Self.original)
    draft.forgettingPassword = true
    #expect(draft.changes(from: Self.original) == .init(password: .forget))
  }

  @Test func forgettingWhatIsntSavedAndSignInWithoutASectionChangeNothing() {
    var unsaved = Self.original
    unsaved.signIn?.hasSavedPassword = false
    var draft = ScreenSharingMachineSettingsDraft(unsaved)
    draft.forgettingPassword = true
    #expect(draft.changes(from: unsaved).isEmpty)
    var app = Self.original
    app.signIn = nil
    draft = ScreenSharingMachineSettingsDraft(app)
    draft.newPassword = "ignored"
    draft.changingPassword = true
    #expect(draft.changes(from: app).isEmpty, "a machine without its own sign-in has nothing to change")
  }
}
