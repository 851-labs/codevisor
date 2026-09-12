import CodevisorCore
import CodevisorUI
import SwiftUI

/// Parses and routes codevisor:// deeplinks. Diagnostic chat opens go back
/// through the owner's closures; machine adds stay behind their confirmation
/// alerts via the bindings.
struct HomeExternalRouting: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @State private var pluginLinkError: String?
  @State private var linkedPlugin: ServerPluginSummary?
  @Binding var pendingDeeplink: MachineDeeplink?
  @Binding var pendingPluginInstall: PendingPluginInstall?
  /// Diagnostics builds route codevisor://diagnostic-open-session here;
  /// production passes a no-op.
  let openDiagnosticSession: (UUID) -> Void
  /// Diagnostics builds route codevisor://diagnostic-new-chat here.
  let openDiagnosticNewChat: (String) -> Void

  func body(content: Content) -> some View {
    content
      // Never auto-add machines: the token grants full agent access,
      // so an explicit confirmation always sits between a link and
      // the machine list (same contract as macOS).
      .onOpenURL { url in
        if PluginInstallDeeplink.pluginID(from: url) != nil {
          openPluginLink(url)
          return
        }
        #if DEBUG || NAVIGATION_DIAGNOSTICS
          // A diagnostics build can drive chats without desktop
          // automation of the Simulator. Production builds do not
          // compile these routes.
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
        // codevisor://cloud-auth — the browser handoff back from a
        // cloud sign-in. The one-time token is proof by itself (it
        // expires within minutes and is single-use).
        if let auth = CloudAuthDeeplink.parse(url) {
          Task { await environment.cloud.completeSignIn(ott: auth.ott) }
          return
        }
        // codevisor://install-plugin — never auto-installs: the
        // sheet runs the standard discover→consent flow, so the
        // verbatim commands are always shown before anything runs.
        if let install = PluginInstallDeeplink.parse(url) {
          pendingPluginInstall = PendingPluginInstall(repo: install.repo)
          return
        }
        guard let link = MachineDeeplink.parse(url) else { return }
        pendingDeeplink = link
      }
      .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
        if let url = activity.webpageURL { openPluginLink(url) }
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
