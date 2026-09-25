import AppKit
import OSLog
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

  /// Listing the displays asks `replayd` too, and a wedged one never answers (on tuftlord a
  /// viewer waited forever on the capabilities request, before any capture): the same watchdog
  /// as the capture start restarts it (851-2385).
  static func watchedDisplays() async throws -> [Display] {
    var result: [Display] = []
    let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")
    let recovery = ScreenSharingCaptureStallRecovery.live(
      metrics: ScreenSharingMetrics(), restartCapture: {}, log: { logger.notice("\($0, privacy: .public)") },
      onStalled: { logger.notice("Listing displays didn't return in 5 s; restarting replayd") })
    try await recovery.start { _ in result = try await displays() }
    return result
  }
}
