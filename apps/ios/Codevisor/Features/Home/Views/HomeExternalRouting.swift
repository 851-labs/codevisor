import CodevisorCore
import SwiftUI

/// Everything that enters Home from OUTSIDE the UI — codevisor:// deeplinks
/// and chat-notification taps — parsed and routed in one place. Chat opens
/// go back through the owner's closures (they may switch machines first);
/// machine adds stay behind their confirmation alerts via the bindings.
struct HomeExternalRouting: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var pendingDeeplink: MachineDeeplink?
  @Binding var pendingPluginInstall: PendingPluginInstall?
  /// Opens a chat by id, switching to its machine when needed.
  let openSession: (UUID, String) -> Void
  /// Diagnostics builds route codevisor://diagnostic-open-session here;
  /// production passes a no-op.
  let openDiagnosticSession: (UUID) -> Void

  func body(content: Content) -> some View {
    content
      // Never auto-add machines: the token grants full agent access,
      // so an explicit confirmation always sits between a link and
      // the machine list (same contract as macOS).
      .onOpenURL { url in
        #if DEBUG || NAVIGATION_DIAGNOSTICS
          // A diagnostics build can exercise a specific persisted
          // chat without desktop automation of the Simulator.
          // Production builds do not compile this route.
          if url.host == "diagnostic-open-session",
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
              .queryItems?.first(where: { $0.name == "id" })?.value,
            let id = UUID(uuidString: value)
          {
            openDiagnosticSession(id)
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
      // A notification tap — often for a chat on ANOTHER machine; the
      // fleet notifies from everywhere, so routing must follow.
      .onReceive(
        NotificationCenter.default.publisher(for: .codevisorOpenChatNotification)
      ) { note in
        guard let raw = note.userInfo?["sessionId"] as? String,
          let sessionId = UUID(uuidString: raw),
          let serverId = note.userInfo?["serverId"] as? String
        else { return }
        openSession(sessionId, serverId)
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
  }
}
