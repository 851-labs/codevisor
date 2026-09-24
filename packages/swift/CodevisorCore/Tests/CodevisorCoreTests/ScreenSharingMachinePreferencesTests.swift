import Foundation
import Testing
@testable import CodevisorCore

/// 851-2340: Dynamic Resolution is per machine, on by default, and works for cloud machine ids too.
struct ScreenSharingMachinePreferencesTests {
  @Test func dynamicResolutionIsPerMachineAndOnByDefault() throws {
    let suite = "ScreenSharingMachinePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenSharingMachinePreferences(defaults: defaults)
    #expect(preferences.dynamicResolution(machineId: "remote-vps"))
    preferences.setDynamicResolution(false, machineId: "remote-vps")
    #expect(!preferences.dynamicResolution(machineId: "remote-vps"))
    #expect(preferences.dynamicResolution(machineId: "cloud:device-1"))
    preferences.setDynamicResolution(false, machineId: "cloud:device-1")
    #expect(!ScreenSharingMachinePreferences(defaults: defaults).dynamicResolution(machineId: "cloud:device-1"))
  }
}
