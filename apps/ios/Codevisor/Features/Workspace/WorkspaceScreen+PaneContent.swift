import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

extension WorkspaceScreen {
  var paneBinding: Binding<PaneGroupState> {
    Binding(
      get: { panes },
      set: { newValue in
        if paneState != newValue { paneState = newValue }
        persistCompactPaneState(newValue)
      }
    )
  }

  func paneContent(_ pane: PaneDescriptorState) -> some View {
    WorkspacePaneContentView(
      pane: pane,
      surfacePaneID: paneViewIdentities[pane.id] ?? pane.id,
      layoutNamespaceToken: sessionId == nil ? draftPlaceholderId : nil,
      filePaneModel: { filePaneModel(for: $0) },
      reviewPaneModel: { reviewPaneModel(for: $0) },
      onOpenFiles: { openFiles(pane) },
      chatController: { chatController(for: $0) },
      activeSessionId: activeSessionId,
      session: { session(for: $0) },
      projectList: environment.projectList,
      showsRunPickers: isDraft && !presentsAsStarted,
      initialComposerFocusRequest: composerFocusRequest(for: pane),
      onInitialComposerFocusRequestFulfilled: { request in
        if convertedChatFocusRequest?.request == request {
          convertedChatFocusRequest = nil
        } else {
          onInitialComposerFocusRequestFulfilled?(request)
        }
      },
      transcriptPresentationRole: transcriptPresentationRole,
      onSendAnimationCompleted: onSendAnimationCompleted,
      onSendAnimationStarted: onSendAnimationStarted,
      onComposerWillSend: onComposerWillSend,
      preservesComposerFocusOnSend: false,
      composerTextEditorHandoffRole: composerTextEditorHandoffRole,
      composerTextEditorHandoffID: composerTextEditorHandoffID,
      isNewChatPresentation: isNewChatPresentation,
      hasStarted: presentsAsStarted,
      onWorkspaceReady: onWorkspaceReady,
      connectChat: { await connectChat(sessionId: $0) },
      onConvertToChat: { convertToChat(pane) },
      onConvertToTerminal: { convertToTerminal(pane) },
      onConvertToBrowser: { convertToBrowser(pane) },
      onConvertToReview: { convertToReview(pane) },
      onConvertToSimulator: { convertToSimulator(pane) },
      onConvertToScreenSharing: { convertToScreenSharing(pane) },
      onConvertToPlugin: { convertToPlugin(pane, option: $0) },
      serverConfig: serverConfig,
      workspaceCwd: workspaceCwd,
      machineClient: environment.machines.client(for: resolvedServerId),
      machineId: resolvedServerId,
      browserPaneModel: { browserPaneModel(for: $0) },
      pluginPaneModel: { pluginPaneModel(for: $0) },
      simulatorPaneModel: { simulatorPaneModel(for: $0) },
      screenSharingPaneModel: { screenSharingPaneModel(for: $0) },
      onRenamePane: { renamePane($0, to: $1) }
    )
    .environment(\.openFileDocument, OpenFileDocumentAction { openFileDocument($0, rendered: $1) })
    .environment(\.openSubagent, openSubagentAction)
    .ignoresSafeArea(.container, edges: pane.kind == .plugin ? .bottom : [])
  }

  func composerFocusRequest(for pane: PaneDescriptorState) -> UUID? {
    if let pending = convertedChatFocusRequest, pane.chatSessionId == pending.chatSessionId {
      return pending.request
    }
    return initialComposerFocusRequest
  }

  private func updateBrowserPane(_ id: UUID, _ update: (PaneDescriptorState) -> PaneDescriptorState?) {
    var state = panes
    guard let index = state.panes.firstIndex(where: { $0.id == id }), let updated = update(state.panes[index])
    else { return }

    state.panes[index] = updated
    paneBinding.wrappedValue = state
    publishPane(updated)
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
      updateBrowserPane(pane.id) { BrowserPaneUpdate.navigated($0, to: url, title: title) }
    }
    model.favicons.onShare = { reference, page in
      updateBrowserPane(pane.id) { BrowserPaneUpdate.favicon(reference, savedFor: page, on: $0) }
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
        access: environment.pluginAccess,
        resolveBaseURL: { [weak machines] in
          await machines?.effectiveHTTPBaseURL(forMachineId: serverId)
        },
        recoverConnection: { [weak machines] in
          await machines?.recoverHTTPConnection(forMachineId: serverId)
        }
      )
    }
  }

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
