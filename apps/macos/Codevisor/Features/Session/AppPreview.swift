import Foundation

enum AppPreview {
  static var isRunning: Bool {
    #if DEBUG
      if AppStoreScreenshotData.isEnabled || BentoRender.outputDirectory != nil
        || BentoNotifications.handshakeDirectory != nil
      {
        return true
      }
    #endif
    return ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
  }
}
