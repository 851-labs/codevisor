import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

// MARK: - Pane content

/// The workspace's writable pane state and the view for its active pane,
/// plus the cached browser/plugin models that pane hands its content.
extension WorkspaceScreen {
  var paneBinding: Binding<PaneGroupState> {
    Binding(
      get: { panes },
      set: { newValue in
        paneState = newValue
        persistCompactPaneState(newValue)
      }
    )
  }

  func paneContent(_ pane: PaneDescriptorState) -> some View {
    WorkspacePaneContentView(
      pane: pane,
      chatController: { chatController(for: $0) },
      activeSessionId: activeSessionId,
      session: { session(for: $0) },
      projectList: environment.projectList,
      // The promotion overlay fades the source pickers. Keep their layout
      // intact until it captures the sheet; the canonical route omits them.
      showsRunPickers: composerTextEditorHandoffRole == .promotionSource
        || (isDraft && !presentsAsStarted),
      initialComposerFocusRequest: initialComposerFocusRequest,
      onInitialComposerFocusRequestFulfilled:
        onInitialComposerFocusRequestFulfilled,
      transcriptPresentationRole: transcriptPresentationRole,
      onSendAnimationCompleted: onSendAnimationCompleted,
      onSendAnimationStarted: onSendAnimationStarted,
      onComposerWillSend: onComposerWillSend,
      preservesComposerFocusOnSend: isNewChatPresentation,
      composerTextEditorHandoffRole: composerTextEditorHandoffRole,
      composerTextEditorHandoffID: composerTextEditorHandoffID,
      isNewChatPresentation: isNewChatPresentation,
      hasStarted: presentsAsStarted,
      onWorkspaceReady: onWorkspaceReady,
      connectChat: { await connectChat(sessionId: $0) },
      onConvertToChat: { convertToChat(pane) },
      onConvertToTerminal: { convertToTerminal(pane) },
      onConvertToBrowser: { convertToBrowser(pane) },
      onConvertToPlugin: { convertToPlugin(pane, option: $0) },
      serverConfig: serverConfig,
      workspaceCwd: workspaceCwd,
      machineClient: environment.machines.client(for: resolvedServerId),
      machineId: resolvedServerId,
      browserPaneModel: { browserPaneModel(for: $0) },
      pluginPaneModel: { pluginPaneModel(for: $0) },
      onRenamePane: { renamePane($0, to: $1) }
    )
    // BrowserPaneView extends its page separately so its floating controls
    // retain the home-indicator and keyboard safe areas.
    .ignoresSafeArea(.container, edges: pane.kind == .plugin ? .bottom : [])
  }

  func browserPaneModel(for pane: PaneDescriptorState) -> BrowserPaneModel {
    let machines = environment.machines
    let serverId = resolvedServerId
    let model = BrowserPaneCache.shared.model(for: pane.id) {
      BrowserPaneModel(
        paneId: pane.id, machineId: serverId, machineName: machines.machine(for: serverId)?.name ?? "Machine",
        initialURL: pane.browserURL ?? "https://www.google.com/",
        client: machines.client(for: serverId),
        resolveBaseURL: { [weak machines] in
          await machines?.effectiveHTTPBaseURL(forMachineId: serverId)
        },
        recoverConnection: { [weak machines] in
          await machines?.recoverHTTPConnection(forMachineId: serverId)
        })
    }
    model.onNavigate = { url, title in
      var state = panes
      guard let index = state.panes.firstIndex(where: { $0.id == pane.id }),
        state.panes[index].browserURL != url || state.panes[index].name != title
      else { return }
      state.panes[index].browserURL = url
      state.panes[index].name = title
      paneBinding.wrappedValue = state
      publishPane(state.panes[index])
    }
    model.onOpenLink = { url in
      openBrowserLink(from: pane.id, url: url, configuration: nil)
    }
    model.onCreatePopup = { configuration, url in
      openBrowserLink(from: pane.id, url: url, configuration: configuration)
    }
    model.onClose = { close(pane) }
    return model
  }

  /// The pane's cached plugin model — the webview and its load state
  /// survive tab switches; the cache tears down webviews for panes that
  /// leave the active canvas.
  private func pluginPaneModel(for pane: PaneDescriptorState) -> PluginPaneModel {
    let serverId = resolvedServerId
    let machines = environment.machines
    return PluginPaneCache.shared.model(for: pane.id) {
      PluginPaneModel(
        paneId: pane.id,
        serverId: serverId,
        pluginId: pane.pluginId ?? "",
        paneType: pane.pluginPaneType ?? "",
        workspaceId: resolvedWorkspace?.id,
        cwd: workspaceCwd,
        client: machines.client(for: serverId),
        resolveBaseURL: { [weak machines] in
          await machines?.effectiveHTTPBaseURL(forMachineId: serverId)
        },
        recoverConnection: { [weak machines] in
          await machines?.recoverHTTPConnection(forMachineId: serverId)
        }
      )
    }
  }

  /// `codevisor.setTitle` from a plugin pane: rename the tab like a manual
  /// rename would (persisted + published), matching macOS.
  private func renamePane(_ pane: PaneDescriptorState, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var state = panes
    guard !trimmed.isEmpty,
      let index = state.panes.firstIndex(where: { $0.id == pane.id }),
      state.panes[index].name != trimmed
    else { return }
    state.panes[index].name = trimmed
    paneBinding.wrappedValue = state
    publishPane(state.panes[index])
  }
}
