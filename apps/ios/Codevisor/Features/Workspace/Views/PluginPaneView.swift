import CodevisorCore
import CodevisorUI
import SwiftUI

/// The iOS plugin pane body: the shared WebPaneView once loading, with a
/// native error card (Retry) for token or navigation failures — never a
/// blank webview. State lives in the cached PluginPaneModel, so remounts
/// (tab switches, grid round-trips) re-attach the same webview without
/// reloading.
struct PluginPaneView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  let model: PluginPaneModel
  /// `codevisor.setTitle`: rename the pane's tab (persisted + published).
  let onRename: (String) -> Void

  private var themeTokens: WebPaneThemeTokens {
    WebPaneThemeTokens(palette: theme.palette, isDark: colorScheme == .dark)
  }

  /// The plugin's reload token: `plugin.updated` (restart, re-import,
  /// re-link) bumps it, and the pane re-runs its full token→load flow —
  /// a fresh pane token and URL, not a bare webView.reload(), so relay
  /// origins re-resolve too.
  private var updateRevision: UInt64 {
    environment.pluginUpdateRevision(forServer: model.serverId, pluginId: model.pluginId)
  }

  var body: some View {
    let tokens = themeTokens
    let revision = updateRevision
    ZStack {
      if case let .failed(message) = model.phase {
        errorCard(message: message, tokens: tokens, revision: revision)
      } else {
        WebPaneView(controller: model.ensureController(theme: tokens))
        if model.phase == .loading {
          ProgressView()
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.paneBackground)
    .task(id: model.id) {
      model.onTitleChange = onRename
      model.loadIfNeeded(theme: tokens, updateRevision: revision)
    }
    .onChange(of: revision) { _, moved in
      // Failed panes retry through the same path automatically.
      model.loadIfNeeded(theme: tokens, updateRevision: moved)
    }
    .onChange(of: tokens) { _, updated in
      model.applyTheme(updated)
    }
  }

  private func errorCard(
    message: String,
    tokens: WebPaneThemeTokens,
    revision: UInt64
  ) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "puzzlepiece.extension")
        .font(.system(size: 26, weight: .regular))
        .foregroundStyle(theme.textSecondary)
      Text("Couldn't load this plugin pane")
        .font(.body.weight(.medium))
        .foregroundStyle(theme.textPrimary)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(theme.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      Button("Retry") {
        model.retry(theme: tokens, updateRevision: revision)
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(24)
  }
}
