import SwiftUI
import CodevisorCore

/// codevisor://install-plugin deeplink handling: routes to the selected
/// machine's Plugins settings page with the linked repo staged as a pending
/// install. Never auto-installs — the plugins pane opens the standard
/// discover→consent sheet, so the verbatim commands are always shown before
/// anything runs.
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
