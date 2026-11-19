import CodevisorCore
import CodevisorUI
import ScreenSharingPane

@MainActor
enum AppDeviceDataTeardown {
  static func register() {
    WebsiteDataTeardown.register()
    DeviceDataTeardown.register { closeLiveContent() }
    DeviceDataTeardown.register { forgetLoadedState() }
  }

  private static func closeLiveContent() {
    ChatControllerCache.shared.removeAll()
    TranscriptPresentationSurfaceCache.shared.removeAll()
    TerminalSessionCache.shared.removeAll()
    BrowserPaneCache.shared.removeAll()
    FilePaneCache.shared.removeAll()
    ReviewPaneCache.shared.removeAll()
    SimulatorPaneCache.shared.removeAll()
    PluginPaneCache.shared.removeAll()
    ScreenSharingDesktops.shared.removeAll()
  }

  private static func forgetLoadedState() {
    WorkspacePaneStore.shared.removeAll()
    FileDocumentStore.shared.removeAll()
    BrowserHistory.shared.forgetLoaded()
    FileRecents.shared.forgetLoaded()
  }
}
