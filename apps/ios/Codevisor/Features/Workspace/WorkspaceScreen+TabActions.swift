import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// What a route asks this screen to show. A pushed screen reads it once at
/// mount; a split detail is reused, so it re-reads it on every change.
struct WorkspacePreferredRoute: Equatable {
  var chatSessionId: UUID?
  var paneId: UUID?
}

/// What a mounted workspace screen is actually showing, reported back so a
/// split layout's route can follow it instead of going stale.
struct WorkspacePaneSelection: Equatable {
  var workspaceId: UUID
  var paneId: UUID
}

// MARK: - Tab actions

/// The workspace's few tab operations. Switching tabs happens from the
/// sidebar, which pushes the workspace on the chosen pane.
extension WorkspaceScreen {
  var preferredRoute: WorkspacePreferredRoute {
    WorkspacePreferredRoute(chatSessionId: preferredChatSessionId, paneId: preferredPaneId)
  }

  /// The pane this screen has decided to show, or nil while it has none of
  /// its own. Before `paneState` exists, `panes` is a repository read or a
  /// draft placeholder — the workspace's last selection, not this screen's,
  /// and reporting it would overwrite a route whose pane is still pending.
  /// A draft has no routed workspace to report against either.
  var reportedPaneSelection: WorkspacePaneSelection? {
    guard paneState != nil, let workspaceId, let paneId = panes.selectedPaneId else { return nil }
    return WorkspacePaneSelection(workspaceId: workspaceId, paneId: paneId)
  }

  /// Applies the route's preferred chat/pane to the mounted pane state,
  /// mirroring what `prepare()` does on a first mount. A chat the
  /// workspace has not opened yet is added and published, as there.
  func applyPreferredRoute() {
    // A screen that has not mounted its panes yet is prepare()'s to route.
    guard paneState != nil else { return }
    var state = panes
    var openedPane: PaneDescriptorState?
    if let preferredChatSessionId {
      if let pane = state.panes.first(where: {
        $0.kind == .chat && $0.chatSessionId == preferredChatSessionId
      }) {
        state.selectPane(id: pane.id)
      } else {
        openedPane = state.addChatPane(sessionId: preferredChatSessionId)
      }
    }
    if let preferredPaneId {
      // A pane sync already removed falls back to the last selection.
      state.selectPane(id: preferredPaneId)
    }
    guard state != panes else { return }
    paneBinding.wrappedValue = state
    if let openedPane { publishPane(openedPane) }
    IOSNavigationDiagnostics.record(
      "workspace.applyPreferredRoute",
      "chat=\(preferredChatSessionId.map(Self.diagnosticID) ?? "nil") "
        + "pane=\(preferredPaneId.map(Self.diagnosticID) ?? "nil") "
        + "selected=\(state.selectedPaneId.map(Self.diagnosticID) ?? "nil")"
    )
  }

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
    if pane.kind == .document { FilePaneCache.shared.remove(paneId: pane.id) }
    if pane.kind == .terminal { TerminalSessionCache.shared.remove(terminalKey: pane.terminalKey) }
    if pane.kind == .chat {
      TranscriptPresentationSurfaceCache.shared.remove(paneID: pane.id)
      if let original = paneViewIdentities[pane.id], original != pane.id {
        TranscriptPresentationSurfaceCache.shared.remove(paneID: original)
      }
    }
    if pane.kind == .chat, let sessionId = pane.chatSessionId,
      let closed = environment.projectList.sessions.first(where: {
        $0.serverId == resolvedServerId && $0.id == sessionId
      })
    {
      environment.closeSession(closed)
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
