import SwiftUI
import CodevisorCore

struct PluginInstallDeeplinkHandling: ViewModifier {
  @Environment(\.openSettings) private var openSettings

  func body(content: Content) -> some View {
    content
      .onOpenURL { url in
        guard let deeplink = PluginInstallDeeplink.parse(url) else { return }
        SettingsRouter.shared.pendingPluginInstallSource = deeplink.repo
        SettingsRouter.shared.showPlugins()
        openSettings()
      }
  }
}
