import Foundation
import Testing
@testable import CodevisorCore

/// 851-2340: Dynamic Resolution is per machine and works for cloud machine ids too; off by default (851-2481).
struct ScreenSharingMachinePreferencesTests {
  @Test func dynamicResolutionIsPerMachineAndOffByDefault() throws {
    let suite = "ScreenSharingMachinePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenSharingMachinePreferences(defaults: defaults)
    #expect(!preferences.dynamicResolution(machineId: "remote-vps"))
    preferences.setDynamicResolution(true, machineId: "remote-vps")
    #expect(preferences.dynamicResolution(machineId: "remote-vps"))
    #expect(!preferences.dynamicResolution(machineId: "cloud:device-1"))
    preferences.setDynamicResolution(true, machineId: "cloud:device-1")
    #expect(ScreenSharingMachinePreferences(defaults: defaults).dynamicResolution(machineId: "cloud:device-1"))
  }

  /// 851-2481: choices saved under the old default (on) are reset to off once; later ones are kept.
  @Test func savedChoicesAreResetOnceForTheNewDefault() throws {
    let suite = "ScreenSharingMachinePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "screenSharing.dynamicResolution.remote-vps")
    defaults.set(false, forKey: "screenSharing.dynamicResolution.local")
    defaults.set(0.5, forKey: "screenSharing.soundVolume.remote-vps")
    let preferences = ScreenSharingMachinePreferences(defaults: defaults)
    #expect(!preferences.dynamicResolution(machineId: "remote-vps"))
    #expect(!preferences.dynamicResolution(machineId: "local"))
    #expect(preferences.sound(machineId: "remote-vps").volume == 0.5, "only Dynamic Resolution is reset")
    preferences.setDynamicResolution(true, machineId: "remote-vps")
    #expect(ScreenSharingMachinePreferences(defaults: defaults).dynamicResolution(machineId: "remote-vps"))
  }

  /// 851-2480: HDR is per machine and off until turned on.
  @Test func hdrIsPerMachineAndOffByDefault() throws {
    let suite = "ScreenSharingMachinePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenSharingMachinePreferences(defaults: defaults)
    #expect(!preferences.highDynamicRange(machineId: "cloud:device-1"))
    preferences.setHighDynamicRange(true, machineId: "cloud:device-1")
    #expect(ScreenSharingMachinePreferences(defaults: defaults).highDynamicRange(machineId: "cloud:device-1"))
    #expect(!preferences.highDynamicRange(machineId: "remote-vps"))
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
