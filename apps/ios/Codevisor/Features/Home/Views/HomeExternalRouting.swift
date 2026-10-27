import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeExternalRouting: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var pendingDeviceApproval: CloudDeviceApprovalRequest?
  @State private var linkedCatalogId: String?
  let isOnboardingPresented: Bool
  let openDiagnosticSession: (UUID) -> Void
  let openDiagnosticNewChat: (String) -> Void

  func body(content: Content) -> some View {
    content
      .onOpenURL { url in
        if openDeviceApproval(url) { return }
        if openPluginLink(url) { return }
        #if DEBUG || NAVIGATION_DIAGNOSTICS
          if let diagnostic = IOSDiagnosticDeeplink.parse(url) {
            IOSNavigationDiagnostics.record("diag.deeplink", "\(diagnostic)")
            switch diagnostic {
            case let .openSession(id): openDiagnosticSession(id)
            case let .newChat(text): openDiagnosticNewChat(text)
            case .send:
              NotificationCenter.default.post(name: .codevisorDiagnosticSubmitComposer, object: nil)
            }
            return
          }
        #endif
        if let auth = CloudAuthDeeplink.parse(url) {
          Task { await environment.cloud.completeSignIn(ott: auth.ott) }
        }
      }
      .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
        guard let url = activity.webpageURL else { return }
        if openDeviceApproval(url) { return }
        _ = openPluginLink(url)
      }
      .modifier(PluginLinkRouting(catalogId: $linkedCatalogId))
  }

  private func openPluginLink(_ url: URL) -> Bool {
    guard let catalogId = PluginCatalogLink.catalogId(from: url) else { return false }
    linkedCatalogId = catalogId
    return true
  }

  private func openDeviceApproval(_ url: URL) -> Bool {
    guard let link = CloudDeviceApprovalLink.parse(url) else { return false }
    if pendingDeviceApproval?.link == link { return true }
    pendingDeviceApproval = CloudDeviceApprovalRequest(
      link: link,
      presentsOverOnboarding: pendingDeviceApproval?.presentsOverOnboarding ?? isOnboardingPresented
    )
    return true
  }
}
