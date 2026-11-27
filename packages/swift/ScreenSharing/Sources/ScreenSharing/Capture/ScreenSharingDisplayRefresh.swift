#if os(macOS)
  import AppKit

  enum ScreenSharingDisplayRefresh {
    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    @MainActor static func hz(of displayID: CGDirectDisplayID) -> Double? {
      let screen = NSScreen.screens.first { $0.deviceDescription[screenNumberKey] as? CGDirectDisplayID == displayID }
      if let screen, screen.maximumFramesPerSecond > 0 { return Double(screen.maximumFramesPerSecond) }
      guard let mode = CGDisplayCopyDisplayMode(displayID), mode.refreshRate > 0 else { return nil }

      return mode.refreshRate
    }
  }
#endif
