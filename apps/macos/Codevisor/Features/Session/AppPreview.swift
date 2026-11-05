import Foundation

enum AppPreview {
  static let rendersFixtures: Bool = {
    #if DEBUG
      AppStoreScreenshotData.isEnabled || BentoRender.outputDirectory != nil
        || BentoNotifications.handshakeDirectory != nil
    #else
      false
    #endif
  }()

  static let isRunning = rendersFixtures || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}
