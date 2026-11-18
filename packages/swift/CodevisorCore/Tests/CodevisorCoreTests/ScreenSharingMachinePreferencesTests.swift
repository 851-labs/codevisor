import Foundation
import Testing
@testable import CodevisorCore

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

  @Test func sharedClipboardIsPerMachineAndOnByDefault() throws {
    let suite = "ScreenSharingMachinePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenSharingMachinePreferences(defaults: defaults)
    #expect(preferences.sharedClipboard(machineId: "local"))
    preferences.setSharedClipboard(false, machineId: "local")
    #expect(!ScreenSharingMachinePreferences(defaults: defaults).sharedClipboard(machineId: "local"))
    #expect(preferences.sharedClipboard(machineId: "remote-vps"))
  }

  @Test func screenshotsStayLocalPerMachineAndByDefault() throws {
    let suite = "ScreenSharingMachinePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenSharingMachinePreferences(defaults: defaults)
    #expect(preferences.screenshotsStayLocal(machineId: "local"))
    preferences.setScreenshotsStayLocal(false, machineId: "local")
    #expect(!ScreenSharingMachinePreferences(defaults: defaults).screenshotsStayLocal(machineId: "local"))
    #expect(preferences.screenshotsStayLocal(machineId: "remote-vps"))
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

  @Test func theLastPictureSizeIsPerMachineAndAbsentUntilSeen() throws {
    let suite = "ScreenSharingMachinePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenSharingMachinePreferences(defaults: defaults)
    #expect(preferences.pictureSize(machineId: "local") == nil)
    preferences.setPictureSize(CGSize(width: 3024, height: 1964), machineId: "local")
    let reopened = ScreenSharingMachinePreferences(defaults: defaults)
    #expect(reopened.pictureSize(machineId: "local") == CGSize(width: 3024, height: 1964))
    #expect(preferences.pictureSize(machineId: "remote-vps") == nil)
  }

  @Test func aSavedPictureSizeThatIsNotARealSizeIsIgnored() throws {
    let suite = "ScreenSharingMachinePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenSharingMachinePreferences(defaults: defaults)
    let saved: [Any] = [
      [-3024.0, 1964.0], [3024.0, 0.0], [Double.infinity, 1964.0], [3024.0, Double.nan], [3024.0],
      [3024.0, 1964.0, 2.0], ["3024", "1964"], "3024x1964",
    ]
    for value in saved {
      defaults.set(value, forKey: "screenSharing.pictureSize.local")
      #expect(preferences.pictureSize(machineId: "local") == nil, "\(value)")
    }
  }
}
