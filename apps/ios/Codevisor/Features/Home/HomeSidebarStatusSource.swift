import CodevisorCore
import CodevisorUI
import Foundation

@MainActor
struct HomeSidebarStatusSource {
  let environment: AppEnvironment

  var workspaces: SidebarRowStatuses {
    let list = environment.projectList
    return SidebarRowStatuses(
      environment.navigationStore.workspaceEntries.sidebar, chats: list.sessions, mainChat: list.mainChat(of:),
      activity: activity(of:))
  }

  func status(of chat: ChatSession) -> SidebarRowStatus? {
    SidebarRowStatuses.status(of: chat, among: environment.projectList.sessions, activity: activity(of:))
  }

  func isWorking(_ chat: ChatSession) -> Bool {
    ChatControllerCache.shared.isInProgress(chat)
  }

  private func activity(of chat: ChatSession) -> SidebarChatActivity {
    SidebarChatActivity(
      session: chat, isWorking: isWorking(chat), isSettingUp: ChatControllerCache.shared.isSettingUp(chat))
  }
}
