import CodevisorCore
import CodevisorUI
import SwiftUI

struct CloudAuthDeeplinkHandling: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.openSettings) private var openSettings

  func body(content: Content) -> some View {
    content
      .onOpenURL { url in
        if BrowserSignIn.shared.receive(url) { return }
        guard let deeplink = CloudAuthDeeplink.parse(url) else { return }
        Task { await environment.cloud.completeSignIn(ott: deeplink.ott) }
        SettingsRouter.shared.showMachines()
        openSettings()
      }
  }
}
