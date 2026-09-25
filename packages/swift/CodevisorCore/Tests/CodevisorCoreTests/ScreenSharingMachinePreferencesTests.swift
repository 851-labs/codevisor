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

  @Test func lastConnectedIsPerMachineAndAbsentUntilSet() throws {
    let suite = "ScreenSharingMachinePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenSharingMachinePreferences(defaults: defaults)
    #expect(preferences.lastConnected(machineId: "local") == nil)
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    preferences.setLastConnected(date, machineId: "local")
    #expect(ScreenSharingMachinePreferences(defaults: defaults).lastConnected(machineId: "local") == date)
    #expect(preferences.lastConnected(machineId: "remote-vps") == nil)
  }
}
