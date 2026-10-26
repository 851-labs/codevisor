import Foundation

enum AppPreview {
  static var rendersFixtures: Bool {
    #if DEBUG
      AppStoreScreenshotData.isEnabled || BentoRender.outputDirectory != nil
        || BentoNotifications.handshakeDirectory != nil
    #else
      false
    #endif
  }

  static var isRunning: Bool {
    rendersFixtures || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
  }
}
