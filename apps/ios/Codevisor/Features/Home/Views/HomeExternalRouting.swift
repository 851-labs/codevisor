import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeExternalRouting: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @State private var pluginLinkError: String?
  @State private var linkedPlugin: ServerPluginSummary?
  @Binding var pendingDeviceApproval: CloudDeviceApprovalRequest?
  @Binding var pendingPluginInstall: PendingPluginInstall?
  let isOnboardingPresented: Bool
  let openDiagnosticSession: (UUID) -> Void
  let openDiagnosticNewChat: (String) -> Void

  func body(content: Content) -> some View {
    content
      .onOpenURL { url in
        if openDeviceApproval(url) { return }
        if PluginInstallDeeplink.pluginID(from: url) != nil {
          openPluginLink(url)
          return
        }
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
          return
        }
        if let install = PluginInstallDeeplink.parse(url) {
          pendingPluginInstall = PendingPluginInstall(repo: install.repo)
          return
        }
      }
      .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
        guard let url = activity.webpageURL else { return }
        if openDeviceApproval(url) { return }
        openPluginLink(url)
      }
      .alert(
        "Plugin unavailable",
        isPresented: Binding(get: { pluginLinkError != nil }, set: { if !$0 { pluginLinkError = nil } })
      ) {
        Button("OK") { pluginLinkError = nil }
      } message: {
        Text(pluginLinkError ?? "")
      }
      .sheet(item: $pendingPluginInstall) { pending in
        let client = environment.machines.client(
          for: environment.defaultComposerServerId)
        PluginInstallSheet(
          initialSource: pending.repo,
          discover: { source in
            try await client.discoverRemotePlugin(source: source)
          },
          onInstall: { source in
            _ = try await client.importRemotePlugin(source: source)
          }
        )
      }
      .sheet(item: $linkedPlugin) { plugin in
        NavigationStack {
          PluginDetailScreen(plugin: plugin)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Close") { linkedPlugin = nil }
              }
            }
        }
      }
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

  private func openPluginLink(_ url: URL) {
    guard let id = PluginInstallDeeplink.pluginID(from: url) else { return }
    Task {
      do {
        let client = environment.machines.client(for: environment.defaultComposerServerId)
        if let installed = try? await client.listPlugins().first(where: { $0.id == id }) {
          linkedPlugin = installed
          return
        }
        let entry = try await environment.pluginAccess.catalog.entry(id: id)
        pendingPluginInstall = PendingPluginInstall(repo: entry.repo)
      } catch { pluginLinkError = ErrorReporter.userFacingMessage(for: error) }
    }
  }
}
