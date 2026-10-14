import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

extension HomeView {
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
      moveTab: { tabId, successor, workspace in
        withSidebarReflow {
          environment.workspaceSync.moveTab(tabId, before: successor, inWorkspace: workspace.id)
        }
      },
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

  private func closeSidebarRow(_ row: HomeSidebarTabRow, in ref: HomeSidebarWorkspaceRef) {
    withSidebarReflow {
      if let chatId = row.chatSessionId, let session = projectList.session(chatId, serverId: ref.serverId) {
        environment.closeSession(session)
      } else if let workspace = environment.workspaces.workspace(id: ref.id) {
        closePane(row.id, in: workspace)
      }
      if case .plugin = row.icon { PluginPaneCache.shared.remove(paneId: row.id) }
      if case .browser = row.icon { BrowserPaneCache.shared.remove(paneId: row.id) }
      if case .review = row.icon { ReviewPaneCache.shared.remove(paneId: row.id) }
      if case .simulator = row.icon { SimulatorPaneCache.shared.remove(paneId: row.id) }
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
    environment.workspaces.save(updated)
    environment.workspaceSync.deletePane(
      id: paneId,
      workspaceId: workspace.id,
      optimisticReplacement: replacement,
      client: environment.machines.client(for: workspace.serverId)
    )
  }

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

  func withSidebarReflow(_ change: () -> Void) {
    withAnimation(Motion.listReflow(reduceMotion: reduceMotion), change)
  }

  func commitWorkspaceOrder(_ id: UUID, visibleIDs: [UUID]) {
    guard let workspace = environment.workspaces.workspace(id: id) else { return }
    environment.workspaceSync.reorderWorkspace(
      id: id, visibleIDs: visibleIDs,
      client: environment.machines.client(for: workspace.serverId)
    )
  }
}
