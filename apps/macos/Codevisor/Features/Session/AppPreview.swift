import Foundation

/// Detects SwiftUI preview rendering, so we can skip launching real agent
/// subprocesses (which would hang against the mock preview transport).
enum AppPreview {
  static var isRunning: Bool {
    #if DEBUG
      if AppStoreScreenshotData.isEnabled { return true }
    #endif
    return ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
  }
}
