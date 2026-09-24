import CodevisorCore
import Foundation

extension SessionStore {
  /// Navigation commits layout without constructing panes or connecting a
  /// routing chat. The mounted container observes the same revision as the
  /// sidebar, including when the selected session itself does not change.
  @discardableResult
  func selectDestination(_ destination: WorkspaceDestination, in workspaceId: UUID) -> Bool {
    guard var workspace = environment.workspaces.workspace(id: workspaceId) else { return false }
    let previous = workspace
    guard workspace.selectDestination(destination) else { return false }
    if workspace != previous || navigationWorkspaceId != workspaceId {
      navigationWorkspaceId = workspaceId
      navigationRevision &+= 1
    }
    if workspace != previous {
      environment.workspaces.save(workspace)
      if previous.selectedCenterTabId != workspace.selectedCenterTabId,
        let oldTab = previous.selectedCenterTab
      {
        // Release terminal keyboard focus using only existing panes. Browser
        // views own visibility, including their separate detached windows.
        for leaf in oldTab.root.allGroups {
          let key = CenterLeafKey(workspaceId: workspaceId, groupId: leaf.id)
          if let model = centerLeafGroups[key],
            let paneId = model.state.selectedPaneId,
            let pane = model.live[paneId], pane.kind == .terminal
          {
            pane.visibilityChanged(false)
          }
        }
      }
      // Legacy groups may contain several panes. Adopt only their selection;
      // native visibility and focus follow after the destination is mounted.
      if let tab = workspace.selectedCenterTab,
        let state = tab.root.group(id: tab.activeLeafId),
        let model = centerLeafGroups[.init(workspaceId: workspaceId, groupId: tab.activeLeafId)]
      {
        model.state.selectedPaneId = state.selectedPaneId
      }
      workspaceLayoutRevision += 1
    }
    return true
  }

  /// Direct chat links and archive restoration select the chat before the
  /// destination view is evaluated. A restored chat regains a tab in its
  /// original workspace even when closing it removed its old pane.
  func selectChat(_ session: ChatSession) {
    guard
      let project = environment.projectList.projects.first(where: {
        $0.serverId == session.serverId && $0.id == session.projectId
      })
    else { return }
    let hadChatPane =
      environment.workspaces.workspaceId(forSession: session.id)
      .flatMap { environment.workspaces.workspace(id: $0)?.tabId(containingChat: session.id) } != nil
    var workspace = workspace(for: session, project: project)
    if workspace.tabId(containingChat: session.id) == nil {
      let group = PaneGroupState.centerInitial(sessionId: session.id)
      workspace.centerTabs.append(WorkspaceTab(root: .leaf(group)))
      environment.workspaces.save(workspace)
    }
    if !hadChatPane {
      // The one-time migration is complete. Publish panes created by explicit
      // navigation now so the next snapshot and other devices retain them.
      for pane in workspace.centerTabs.flatMap({ $0.root.allGroups.flatMap { $0.state.panes } })
      where pane.chatSessionId == session.id {
        environment.workspaceSync.publishPane(
          pane, workspaceId: workspace.id,
          client: environment.machines.client(for: session.serverId))
      }
    }
    selectDestination(.chat(session.id), in: workspace.id)
  }
}
