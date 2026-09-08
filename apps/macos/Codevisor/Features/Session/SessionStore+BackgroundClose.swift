import CodevisorCore
import Foundation

extension SessionStore {
  /// Closes an off-screen tab through the same pane lifecycle as a mounted
  /// container, without running that container's stale navigation/focus hooks.
  func closeBackgroundTab(
    _ action: CenterTabRequest.Action,
    in workspace: Workspace,
    routingSession: ChatSession?
  ) {
    guard let session = routingSession,
      let project = environment.projectList.projects.first(where: {
        $0.serverId == workspace.serverId && $0.id == workspace.projectId
      })
    else { return }
    let tab: WorkspaceTab
    let leafIds: [UUID]
    switch action {
    case let .close(tabId):
      guard let target = workspace.centerTabs.first(where: { $0.id == tabId }) else { return }
      tab = target
      leafIds = target.root.allGroups.map(\.id)
    case let .closeLeaf(leafId):
      guard let target = workspace.centerTabs.first(where: { $0.root.group(id: leafId) != nil }) else {
        return
      }
      tab = target
      leafIds = [leafId]
    default:
      return
    }
    guard let tabIndex = workspace.centerTabs.firstIndex(where: { $0.id == tab.id }) else { return }
    for leafId in leafIds {
      let model = centerGroup(
        leafId: leafId, workspace: workspace, session: session, project: project
      )
      let previousClose = model.onPaneClosed
      let previousCanDissolve = model.canDissolve
      model.canDissolve = { true }
      model.onPaneClosed = { [weak self] descriptor in
        guard let self else { return }
        if descriptor.kind != .newTab, !descriptor.attachOnly,
          descriptor.kind != .chat || descriptor.chatSessionId != nil
        {
          recordClosedPane(
            ClosedPaneRecord(descriptor: descriptor, tabId: tab.id, tabIndex: tabIndex),
            workspaceId: workspace.id
          )
        }
        if descriptor.kind == .chat {
          if let chatId = descriptor.chatSessionId,
            let chat = environment.projectList.sessions.first(where: {
              $0.serverId == workspace.serverId && $0.id == chatId
            })
          {
            environment.archiveSession(chat)
          } else if descriptor.chatSessionId == nil {
            removePaneDraft(paneId: descriptor.id)
          }
        }
      }
      defer {
        model.onPaneClosed = previousClose
        model.canDissolve = previousCanDissolve
      }
      let paneIds: [UUID]
      if case .closeLeaf = action {
        paneIds = model.state.selectedPaneId.map { [$0] } ?? []
      } else {
        paneIds = model.state.panes.map(\.id)
      }
      for paneId in paneIds {
        model.closePane(id: paneId, activateRemainingPane: false)
      }
    }
    guard var updated = environment.workspaces.workspace(id: workspace.id) else { return }
    updated.pruneClosedCenterTab(tab.id)
    environment.workspaces.save(updated)
    for leafId in leafIds
    where updated.centerTabs.allSatisfy({ $0.root.group(id: leafId) == nil }) {
      evictCenterLeaf(workspaceId: workspace.id, leafId: leafId)
    }
    workspaceLayoutRevision += 1
  }
}
