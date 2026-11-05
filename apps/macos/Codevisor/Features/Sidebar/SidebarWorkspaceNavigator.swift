import CodevisorCore
import SwiftUI

@MainActor
struct SidebarWorkspaceNavigator {
  let environment: AppEnvironment
  let store: SessionStore?
  @Binding var selection: SidebarSelection?

  func routesSelectedSession(_ workspace: Workspace) -> Bool {
    switch selection {
    case let .session(serverId, sessionId):
      guard serverId == workspace.serverId else { return false }
      return environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
    case let .workspace(serverId, id):
      return serverId == workspace.serverId && id == workspace.id
    case .archivedWorkspace, .bot, .newChat, .none:
      return false
    }
  }

  func activate(_ item: SidebarWorkspaceListItem, tabId: UUID? = nil) {
    guard let tab = activatedTab(of: item.workspace, preferring: tabId) else { return }

    let workspace = item.workspace
    guard store?.selectDestination(.tab(tab.id), in: workspace.id) == true else { return }
    apply(
      workspace.selectionRoute(
        activatedChatSessionId: environment.projectList.routableChat(in: tab, serverId: workspace.serverId)?.id,
        routingSessionId: item.routingSession?.id,
        selectionAlreadyRoutesWorkspace: routesSelectedSession(workspace)
      ))
  }

  private func activatedTab(of workspace: Workspace, preferring tabId: UUID? = nil) -> WorkspaceTab? {
    workspace.centerTabs.first { $0.id == tabId } ?? workspace.selectedCenterTab ?? workspace.centerTabs.first
  }

  private func apply(_ route: WorkspaceSelectionRoute?) {
    switch route {
    case let .session(serverId, id):
      selection = .session(serverId: serverId, id: id)
    case let .workspace(serverId, id):
      selection = .workspace(serverId: serverId, id: id)
    case nil:
      break
    }
  }
}
