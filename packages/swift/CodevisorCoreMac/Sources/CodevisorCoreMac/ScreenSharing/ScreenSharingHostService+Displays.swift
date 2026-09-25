import AppKit
import CodevisorCore
import ScreenSharing

extension ScreenSharingHostService {
  /// This Mac's displays as a viewer picks them: a stable identity (the display's UUID), its
  /// name, and its size in pixels.
  static func displays() async throws -> [Display] {
    try await ScreenSharingCapture.displays().compactMap { display in
      guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue() else { return nil }
      let identity = CFUUIDCreateString(nil, uuid) as String
      let mode = CGDisplayCopyDisplayMode(display.id)
      let pixelScale = mode.map { Double($0.pixelWidth) / Double(max(1, $0.width)) } ?? 1
      let name =
        NSScreen.screens.first {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }?.localizedName ?? "Display"
      return (
        display.id,
        ServerScreenSharingDisplay(
          id: identity, name: name,
          width: Int(Double(display.width) * pixelScale), height: Int(Double(display.height) * pixelScale))
      )
    }
  }
}
