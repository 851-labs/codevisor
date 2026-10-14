import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginPaneView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase
  let model: PluginPaneModel
  let onRename: (String) -> Void

  private var themeTokens: WebPaneThemeTokens {
    WebPaneThemeTokens(palette: theme.palette, isDark: colorScheme == .dark)
  }

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
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
        await model.revalidateAccess()
      }
    }
    .task(id: environment.pluginAccess.revision) {
      model.retry(theme: tokens, updateRevision: revision)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { model.retry(theme: tokens, updateRevision: revision) }
    }
    .onChange(of: revision) { _, moved in
      model.loadIfNeeded(theme: tokens, updateRevision: moved)
    }
    .task(id: environment.machines.httpConnectionState(forMachineId: model.serverId)) {
      await model.connectionDidChange(theme: tokens, updateRevision: revision)
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
