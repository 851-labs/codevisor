import SwiftUI
import CodevisorCore

/// codevisor://cloud-auth?ott=… deeplink handling: completes a cloud sign-in
/// that came back through the default browser (the in-app
/// ASWebAuthenticationSession path never leaves the app) and routes to the
/// Account settings tab so the result is visible.
struct CloudAuthDeeplinkHandling: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.openSettings) private var openSettings

  func body(content: Content) -> some View {
    content
      // No confirmation gate: the one-time token proves a sign-in this
      // user just performed, is single-use, and expires in minutes.
      .onOpenURL { url in
        guard let deeplink = CloudAuthDeeplink.parse(url) else { return }
        Task { await environment.cloud.completeSignIn(ott: deeplink.ott) }
        SettingsRouter.shared.showMachines()
        openSettings()
      }
  }
}
