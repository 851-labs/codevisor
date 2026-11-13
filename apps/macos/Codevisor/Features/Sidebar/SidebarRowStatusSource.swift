import CodevisorCore
import CodevisorUI
import Foundation

@MainActor
struct SidebarRowStatusSource {
  let environment: AppEnvironment
  let store: SessionStore?

  var statuses: SidebarRowStatuses {
    let list = environment.projectList
    return SidebarRowStatuses(
      environment.navigationStore.workspaceEntries.sidebar, chats: list.sessions, mainChat: list.mainChat(of:),
      activity: activity(of:), chatless: terminalActivity(of:))
  }

  private func activity(of chat: ChatSession) -> SidebarChatActivity {
    SidebarChatActivity(session: chat, isWorking: isWorking(chat), isSettingUp: store?.isSettingUp(chat) == true)
  }

  private func isWorking(_ chat: ChatSession) -> Bool {
    store?.isInProgress(chat) ?? (chat.sidebarState == .inProgress)
  }

  private func terminalActivity(of item: WorkspaceSidebarItem) -> SidebarChatActivity? {
    let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace
    guard workspace?.allPanes.contains(where: { $0.terminalAgentStatus == .working }) == true else { return nil }
    return SidebarChatActivity(isWorking: true)
  }
}
