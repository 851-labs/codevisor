import CodevisorCore
import CodevisorUI
import Foundation

@MainActor
struct HomeSidebarStatusSource {
  private let statuses: SidebarRowStatuses

  init(environment: AppEnvironment) {
    let sessions = ChatControllerCache.shared
    let list = environment.projectList
    statuses = SidebarRowStatuses(
      environment.navigationStore.workspaceEntries.sidebar, chats: list.sessions, mainChat: list.mainChat(of:)
    ) { chat in
      SidebarChatActivity(
        session: chat, isWorking: sessions.isInProgress(chat), isSettingUp: sessions.isSettingUp(chat))
    }
  }

  func status(of workspaceId: UUID) -> SidebarRowStatus? {
    statuses.status(of: workspaceId)
  }
}
