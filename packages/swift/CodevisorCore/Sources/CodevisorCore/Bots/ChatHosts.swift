import Foundation

public enum ChatHost: Equatable {
  case own
  case bot(Bot)
  case guest(Workspace)
}

@MainActor
public struct ChatHosts {
  let projectList: ProjectListModel
  let bots: BotListModel
  let workspaces: any WorkspaceRepository

  public init(projectList: ProjectListModel, bots: BotListModel, workspaces: any WorkspaceRepository) {
    self.projectList = projectList
    self.bots = bots
    self.workspaces = workspaces
  }

  public func host(of chat: ChatSession) -> ChatHost {
    if let bot = botShowing(chat) { return .bot(bot) }
    if let workspace = guestWorkspace(of: chat) { return .guest(workspace) }
    return .own
  }

  public func botShowing(_ chat: ChatSession) -> Bot? {
    var current = chat
    var seen: Set<UUID> = [chat.id]
    while let owner = projectList.parent(of: current), seen.insert(owner.id).inserted {
      if let bot = bots.bot(forSession: owner.id, serverId: owner.serverId) { return bot }
      current = owner
    }
    return nil
  }

  private func guestWorkspace(of chat: ChatSession) -> Workspace? {
    let hostId = workspaces.workspaceId(forSession: chat.id) ?? projectList.owningWorkspaceId(of: chat)
    guard let hostId, let host = workspaces.workspace(id: hostId), !bots.ownsWorkspace(host),
      host.serverId != chat.serverId || host.projectId != chat.projectId
    else { return nil }
    return host
  }
}

extension AppEnvironment {
  public var chatHosts: ChatHosts {
    ChatHosts(projectList: projectList, bots: bots, workspaces: workspaces)
  }
}
