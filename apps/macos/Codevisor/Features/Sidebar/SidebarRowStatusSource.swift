import CodevisorCore
import CodevisorUI
import Foundation

@MainActor
struct SidebarRowStatusSource {
  let environment: AppEnvironment
  let store: SessionStore?

  var statuses: SidebarRowStatuses {
    SidebarRowStatuses(environment.navigationStore.workspaceEntries.sidebar, activity: activity)
  }

  func item(_ workspaceId: UUID) -> WorkspaceSidebarItem? {
    environment.navigationStore.workspaceEntries.sidebar.first { $0.id == workspaceId }
  }

  private func activity(of item: WorkspaceSidebarItem) -> SidebarChatActivity? {
    if let chat = environment.projectList.mainChat(of: item) {
      return SidebarChatActivity(
        session: chat, isWorking: isWorking(chat), isSettingUp: store?.isSettingUp(chat) == true)
    }
    guard hasWorkingTerminal(item) else { return nil }
    return SidebarChatActivity(isWorking: true)
  }

  private func isWorking(_ chat: ChatSession) -> Bool {
    store?.isInProgress(chat) ?? (chat.sidebarState == .inProgress)
  }

  private func hasWorkingTerminal(_ item: WorkspaceSidebarItem) -> Bool {
    let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace
    return workspace?.allPanes.contains { $0.terminalAgentStatus == .working } == true
  }
}
