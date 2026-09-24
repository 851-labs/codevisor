import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// Answers the sidebar rows' requests: opening, closing, renaming, and
/// adding tabs. The sections themselves are built by `HomeSidebarLiveList`
/// from Core's precomputed sidebar.
extension HomeView {
  // MARK: - Actions

  var sidebarActions: HomeSidebarActions {
    HomeSidebarActions(
      open: { row, workspace in openSidebarRow(row, in: workspace) },
      close: { row, workspace in closeSidebarRow(row, in: workspace) },
      rename: { row, workspace in
        guard let tabId = row.renamableTabId else { return }
        tabRenameTitle = row.title
        renamingTab = HomeTabRenameRequest(workspaceId: workspace.id, tabId: tabId, chatSessionId: row.chatSessionId)
      },
      newTab: { workspace in addSidebarTab(in: workspace) },
      renameWorkspace: { ref in
        guard let workspace = environment.workspaces.workspace(id: ref.id) else { return }
        workspaceRenameTitle = workspace.name
        renamingWorkspace = workspace
      },
      archiveWorkspace: { ref in
        guard let workspace = environment.workspaces.workspace(id: ref.id) else { return }
        withSidebarReflow { environment.archiveWorkspace(workspace) }
      },
      reorder: { id, ids in commitWorkspaceOrder(id, visibleIDs: ids) },
      openInNewWindow: UIApplication.shared.supportsMultipleScenes
        ? { row, workspace in
          openWindow(
            value: WorkspaceWindowRoute(
              serverId: workspace.serverId, workspaceId: workspace.id, anchorSessionId: workspace.anchorSessionId,
              chatSessionId: row.chatSessionId, paneId: row.id))
        } : nil,
      didSelectInSplit: { dismissOverlaySidebarAfterSelection() },
      refresh: { await refreshNavigation() }
    )
  }

  /// Chat rows open their chat like any chat route; other tabs mount the
  /// workspace through its anchor chat and name the pane to show.
  private func openSidebarRow(_ row: HomeSidebarTabRow, in workspace: HomeSidebarWorkspaceRef) {
    if let chatId = row.chatSessionId, let session = projectList.session(chatId, serverId: workspace.serverId) {
      openChat(session)
      return
    }
    IOSNavigationDiagnostics.record(
      "home.openPane",
      "workspace=\(shortID(workspace.id)) pane=\(shortID(row.id)) pathBefore=\(navigationPathSummary(path))"
    )
    openRoute(
      .workspace(
        serverId: workspace.serverId,
        workspaceId: workspace.id,
        anchorSessionId: workspace.anchorSessionId,
        preferredChatSessionId: nil,
        preferredPaneId: row.id
      )
    )
  }

  /// A background close, without mounting the workspace. Chats archive
  /// (which closes their pane locally and on the server); other panes take
  /// the same last-pane-becomes-New-Tab path the workspace screen uses.
  private func closeSidebarRow(_ row: HomeSidebarTabRow, in ref: HomeSidebarWorkspaceRef) {
    withSidebarReflow {
      if let chatId = row.chatSessionId, let session = projectList.session(chatId, serverId: ref.serverId) {
        environment.closeSession(session)
      } else if let workspace = environment.workspaces.workspace(id: ref.id) {
        closePane(row.id, in: workspace)
      }
      if case .plugin = row.icon { PluginPaneCache.shared.remove(paneId: row.id) }
      if case .browser = row.icon { BrowserPaneCache.shared.remove(paneId: row.id) }
    }
  }

  private func closePane(_ paneId: UUID, in workspace: Workspace) {
    var state = WorkspaceScreen.compactPaneState(from: workspace)
    if let closed = state.panes.first(where: { $0.id == paneId }), closed.kind == .terminal {
      TerminalSessionCache.shared.remove(terminalKey: closed.terminalKey)
    }
    let replacement: PaneDescriptorState?
    if state.panes.count == 1 {
      replacement = state.replacePaneWithNewTab(id: paneId)
      guard replacement != nil else { return }
    } else {
      replacement = nil
      guard state.closePane(id: paneId) != nil else { return }
    }
    var updated = workspace
    WorkspaceScreen.applyCompactPaneState(state, to: &updated)
    // Saving updates the workspace's entry, which re-renders its section.
    environment.workspaces.save(updated)
    environment.workspaceSync.deletePane(
      id: paneId,
      workspaceId: workspace.id,
      optimisticReplacement: replacement,
      client: environment.machines.client(for: workspace.serverId)
    )
  }

  /// Adds a New Tab page to the workspace and opens it there.
  private func addSidebarTab(in ref: HomeSidebarWorkspaceRef) {
    guard var workspace = environment.workspaces.workspace(id: ref.id) else { return }
    var state = WorkspaceScreen.compactPaneState(from: workspace)
    let pane = state.addNewTabPane()
    WorkspaceScreen.applyCompactPaneState(state, to: &workspace)
    withSidebarReflow { environment.workspaces.save(workspace) }
    environment.workspaceSync.publishPane(
      pane,
      workspaceId: workspace.id,
      client: environment.machines.client(for: ref.serverId)
    )
    openRoute(
      .workspace(
        serverId: ref.serverId,
        workspaceId: ref.id,
        anchorSessionId: ref.anchorSessionId,
        preferredChatSessionId: nil,
        preferredPaneId: pane.id
      )
    )
  }

  /// Chat labels belong to the shared session record.
  func renameSidebarTab(_ request: HomeTabRenameRequest, to title: String) {
    environment.workspaceSync.renameTab(
      workspaceId: request.workspaceId, tabId: request.tabId, chatSessionId: request.chatSessionId, to: title
    )
  }

  func renameWorkspace(_ renamed: Workspace) {
    withSidebarReflow {
      environment.workspaceSync.renameWorkspace(
        renamed, client: environment.machines.client(for: renamed.serverId)
      )
    }
  }

  /// A local sidebar edit: the entries it touches update synchronously, so
  /// the resulting row reflow animates with it.
  func withSidebarReflow(_ change: () -> Void) {
    withAnimation(Motion.listReflow(reduceMotion: reduceMotion), change)
  }

  /// Only the dragged workspace receives a new shared position.
  func commitWorkspaceOrder(_ id: UUID, visibleIDs: [UUID]) {
    guard let workspace = environment.workspaces.workspace(id: id) else { return }
    environment.workspaceSync.reorderWorkspace(
      id: id, visibleIDs: visibleIDs,
      client: environment.machines.client(for: workspace.serverId)
    )
  }
}
