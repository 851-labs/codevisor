import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

// MARK: - Tab actions

/// The workspace's few tab operations. Switching tabs happens from the
/// sidebar, which pushes the workspace on the chosen pane.
extension WorkspaceScreen {
  func select(_ pane: PaneDescriptorState) {
    var state = panes
    state.selectPane(id: pane.id)
    paneBinding.wrappedValue = state
  }

  /// Any tab can close — chats included, as on macOS. A final-pane close is
  /// optimistic conversion of that same identity; the server atomically
  /// confirms the conversion so two clients cannot manufacture replacements.
  func close(_ pane: PaneDescriptorState) {
    let owningWorkspaceId = resolvedWorkspace?.id
    var state = panes
    let replacement: PaneDescriptorState?
    if state.panes.count == 1 {
      replacement = state.replacePaneWithNewTab(id: pane.id)
      guard replacement != nil else { return }
    } else {
      replacement = nil
      guard state.closePane(id: pane.id) != nil else { return }
    }
    withAnimation(Motion.listReflow(reduceMotion: accessibilityReduceMotion)) {
      paneBinding.wrappedValue = state
    }
    if pane.kind == .plugin {
      // Closing the tab drops this client's webview and web-content
      // process. The machine-side plugin remains available to other
      // clients, panes, and tools until the Codevisor server stops.
      PluginPaneCache.shared.remove(paneId: pane.id)
    }
    if pane.kind == .browser {
      BrowserPaneCache.shared.remove(paneId: pane.id)
    }
    if pane.kind == .chat {
      TranscriptPresentationSurfaceCache.shared.remove(paneID: pane.id)
    }
    if pane.kind == .chat, let sessionId = pane.chatSessionId,
      let closed = environment.projectList.sessions.first(where: {
        $0.serverId == resolvedServerId && $0.id == sessionId
      })
    {
      environment.archiveSession(closed)
    }
    if let workspaceId = owningWorkspaceId {
      environment.workspaceSync.deletePane(
        id: pane.id,
        workspaceId: workspaceId,
        optimisticReplacement: replacement,
        client: environment.machines.client(for: resolvedServerId)
      )
    }
  }

  /// Adds a New Tab page and shows it; its page offers what to create.
  func addTab() {
    if let sourcePane = activePane ?? panes.panes.first {
      chatController(for: sourcePane)?.rememberCurrentComposerConfiguration()
    }
    var state = panes
    let newPane = state.addNewTabPane()
    state.selectPane(id: newPane.id)
    paneBinding.wrappedValue = state
    publishPane(newPane)
  }
}
