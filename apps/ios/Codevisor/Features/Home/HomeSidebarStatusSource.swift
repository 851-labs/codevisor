import CodevisorCore
import CodevisorUI
import Foundation

@MainActor
struct HomeSidebarStatusSource {
  let environment: AppEnvironment
  let statuses: SidebarRowStatuses

  init(environment: AppEnvironment) {
    self.environment = environment
    let sessions = ChatControllerCache.shared
    let list = environment.projectList
    statuses = SidebarRowStatuses(environment.navigationStore.workspaceEntries.sidebar) { item in
      list.mainChat(of: item).map {
        SidebarChatActivity(session: $0, isWorking: sessions.isInProgress($0), isSettingUp: sessions.isSettingUp($0))
      }
    }
  }

  func status(of workspaceId: UUID) -> (status: SidebarRowStatus?, asking: HomeSidebarWorkspaceRef?) {
    let status = statuses.status(of: workspaceId)
    guard let askingID = status?.askingWorkspaceID, askingID != workspaceId else { return (status, nil) }
    return (status, ref(askingID))
  }

  private func ref(_ workspaceId: UUID) -> HomeSidebarWorkspaceRef? {
    guard let item = environment.navigationStore.workspaceEntries.sidebar.first(where: { $0.id == workspaceId })
    else { return nil }
    return HomeSidebarWorkspaceRef(
      id: item.id, serverId: item.serverId, anchorSessionId: environment.projectList.mainChat(of: item)?.id)
  }
}
