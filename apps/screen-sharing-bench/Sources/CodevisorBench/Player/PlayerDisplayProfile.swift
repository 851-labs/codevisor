@preconcurrency import ColorSync
import CoreGraphics
import Foundation

enum PlayerDisplayProfile {
  private static let sRGB = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")

  static func assignSRGB(to display: CGDirectDisplayID) -> Bool {
    set(sRGB as CFURL, on: display)
  }

  static func clear(_ display: CGDirectDisplayID) {
    _ = set(kCFNull, on: display)
  }

  private static func set(_ profile: CFTypeRef, on display: CGDirectDisplayID) -> Bool {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return false }

    let profiles =
      [
        kColorSyncDeviceDefaultProfileID.takeUnretainedValue(): profile,
        kColorSyncProfileUserScope.takeUnretainedValue(): kCFPreferencesCurrentUser,
      ] as CFDictionary
    return ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, profiles)
  }
}
