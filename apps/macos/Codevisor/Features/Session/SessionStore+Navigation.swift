import CodevisorCore
import CodevisorUI
import Foundation

extension SessionStore {
  @discardableResult
  func selectDestination(_ destination: WorkspaceDestination, in workspaceId: UUID) -> Bool {
    guard var workspace = environment.workspaces.workspace(id: workspaceId) else { return false }
    let previous = workspace
    guard workspace.selectDestination(destination) else { return false }
    let changesWorkspace = navigationWorkspaceId != workspaceId
    if changesWorkspace || previous.selectedCenterTabId != workspace.selectedCenterTabId {
      NavigationSwitchTrace.shared.begin(workspaceChanged: changesWorkspace)
    }
    if workspace != previous || changesWorkspace {
      navigationWorkspaceId = workspaceId
      navigationRevision &+= 1
    }
    if workspace != previous {
      environment.workspaces.save(workspace)
      if previous.selectedCenterTabId != workspace.selectedCenterTabId,
        let oldTab = previous.selectedCenterTab
      {
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
      if let tab = workspace.selectedCenterTab,
        let state = tab.root.group(id: tab.activeLeafId),
        let model = centerLeafGroups[.init(workspaceId: workspaceId, groupId: tab.activeLeafId)]
      {
        model.state.selectedPaneId = state.selectedPaneId
      }
    }
    return true
  }

  @discardableResult
  func selectChat(_ session: ChatSession) -> SidebarSelection {
    let bot = environment.botPages.show(session)
    if let bot { botPageFocusRequest = BotPageFocusRequest(workspaceId: bot.workspaceId) }
    if let bot, bot.sessionId != session.id { return selection(of: bot) }
    let ownSelection = bot.map(selection(of:)) ?? .session(serverId: session.serverId, id: session.id)
    guard
      let project = environment.projectList.projects.first(where: {
        $0.serverId == session.serverId && $0.id == session.projectId
      })
    else { return ownSelection }
    var workspace = workspace(for: session, project: project)
    let runsElsewhere = workspace.serverId != session.serverId
    let isGuest = runsElsewhere || workspace.projectId != session.projectId
    let hadChatPane =
      isGuest
      ? workspace.tabId(containingChat: session.id) != nil
      : environment.workspaces.workspaceId(forSession: session.id)
        .flatMap { environment.workspaces.workspace(id: $0)?.tabId(containingChat: session.id) } != nil
    if workspace.tabId(containingChat: session.id) == nil {
      let group = PaneGroupState.centerInitial(
        sessionId: session.id,
        machineKey: runsElsewhere ? environment.machines.syncKey(forMachineId: session.serverId) : nil)
      workspace.centerTabs.append(WorkspaceTab(root: .leaf(group)))
      environment.workspaces.save(workspace)
    }
    if !hadChatPane {
      for pane in workspace.centerTabs.flatMap({ $0.root.allGroups.flatMap { $0.state.panes } })
      where pane.chatSessionId == session.id {
        environment.workspaceSync.publishPane(
          pane, workspaceId: workspace.id,
          client: environment.machines.client(for: workspace.serverId))
      }
    }
    selectDestination(.chat(session.id), in: workspace.id)
    return isGuest ? .workspace(serverId: workspace.serverId, id: workspace.id) : ownSelection
  }

  func closePage(of bot: Bot) {
    environment.botThreads.closePage(of: bot)
    botPageFocusRequest = BotPageFocusRequest(workspaceId: bot.workspaceId)
  }

  private func selection(of bot: Bot) -> SidebarSelection {
    .bot(serverId: bot.serverId, id: bot.id)
  }
}
