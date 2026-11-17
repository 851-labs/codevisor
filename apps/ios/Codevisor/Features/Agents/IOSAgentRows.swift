import CodevisorCore
import CodevisorUI
import Foundation

struct IOSAgentRow: Identifiable {
  enum Subject {
    case bot
    case workspace(Workspace)
    case chat
  }

  let chat: ChatSession
  let details: HomeSidebarRowDetails
  let subject: Subject

  var id: UUID { chat.id }
}

@MainActor
struct IOSAgentRows {
  let environment: AppEnvironment
  let gitLookups: SidebarGitLookups
  let rowDetails: [SidebarRowDetail]

  func rows(for chats: [ChatSession]) -> [IOSAgentRow] {
    let statuses = HomeSidebarStatusSource(environment: environment)
    return chats.map { row(for: $0, status: statuses.status(of: $0)) }
  }

  private var builder: HomeSidebarContentBuilder {
    HomeSidebarContentBuilder(environment: environment, gitLookups: gitLookups)
  }

  private func row(for chat: ChatSession, status: SidebarRowStatus?) -> IOSAgentRow {
    if environment.bots.bot(forSession: chat.id, serverId: chat.serverId) != nil {
      return IOSAgentRow(chat: chat, details: chatDetails(chat, status: status), subject: .bot)
    }
    if let item = ownItem(of: chat), let workspace = ownWorkspace(item) {
      let details = builder.agentDetails(for: workspace, item: item, rowDetails: rowDetails, status: status)
      return IOSAgentRow(chat: chat, details: details, subject: .workspace(workspace))
    }
    return IOSAgentRow(chat: chat, details: chatDetails(chat, status: status), subject: .chat)
  }

  private func chatDetails(_ chat: ChatSession, status: SidebarRowStatus?) -> HomeSidebarRowDetails {
    builder.agentDetails(for: chat, rowDetails: rowDetails, status: status)
  }

  private func ownItem(of chat: ChatSession) -> WorkspaceSidebarItem? {
    guard let workspaceId = environment.workspaces.workspaceId(forSession: chat.id) else { return nil }
    let item = environment.navigationStore.workspaceEntries.sidebar.first {
      $0.id == workspaceId && $0.serverId == chat.serverId
    }
    return item.flatMap { environment.projectList.mainChat(of: $0)?.id == chat.id ? $0 : nil }
  }

  private func ownWorkspace(_ item: WorkspaceSidebarItem) -> Workspace? {
    guard let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace,
      !workspace.isArchived
    else { return nil }
    return workspace
  }
}
