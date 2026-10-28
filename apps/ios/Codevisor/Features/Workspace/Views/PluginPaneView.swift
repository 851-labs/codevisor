import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginPaneView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase
  let model: PluginPaneModel
  let onRename: (String) -> Void

  private var themeTokens: WebPaneThemeTokens {
    WebPaneThemeTokens(isDark: colorScheme == .dark)
  }

  var body: some View {
    let tokens = themeTokens
    ZStack {
      if case let .failed(message) = model.phase {
        errorCard(message: message, tokens: tokens)
      } else {
        WebPaneView(controller: model.ensureController(theme: tokens))
        if model.phase == .loading {
          ProgressView()
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: environment.pluginAccess.revision) {
      guard model.phase != .idle else { return }
      model.retry(theme: tokens)
    }
    .task(id: model.id) {
      model.onTitleChange = onRename
      model.loadIfNeeded(theme: tokens)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { model.retry(theme: tokens) }
    }
    .task(id: environment.machines.httpConnectionState(forMachineId: model.serverId)) {
      await model.connectionDidChange(theme: tokens)
    }
    .onChange(of: tokens) { _, updated in
      model.applyTheme(updated)
    }
  }

  private func errorCard(
    message: String,
    tokens: WebPaneThemeTokens
  ) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "puzzlepiece.extension")
        .font(.system(size: 26, weight: .regular))
        .foregroundStyle(.secondary)
      Text("Couldn't load this plugin pane")
        .font(.body.weight(.medium))
        .foregroundStyle(.primary)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      Button("Retry") {
        model.retry(theme: tokens)
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(24)
  }
}
