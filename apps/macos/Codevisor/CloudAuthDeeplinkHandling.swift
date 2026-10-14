import SwiftUI
import CodevisorCore

struct CloudAuthDeeplinkHandling: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.openSettings) private var openSettings

  func body(content: Content) -> some View {
    content
      .onOpenURL { url in
        guard let deeplink = CloudAuthDeeplink.parse(url) else { return }
        Task { await environment.cloud.completeSignIn(ott: deeplink.ott) }
        SettingsRouter.shared.showMachines()
        openSettings()
      }
  }
}
