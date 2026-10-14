import AppKit
import OSLog
import CodevisorCore
import ScreenSharing

extension ScreenSharingHostService {
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
