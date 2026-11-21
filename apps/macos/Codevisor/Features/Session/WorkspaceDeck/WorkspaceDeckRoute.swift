import Foundation

nonisolated enum WorkspaceDeckRoute: Hashable {
  case session(serverId: String, sessionId: UUID)
  case workspace(serverId: String, workspaceId: UUID)
  case bot(serverId: String, botId: UUID)

  init?(_ selection: SidebarSelection?) {
    switch selection {
    case let .session(serverId, id): self = .session(serverId: serverId, sessionId: id)
    case let .workspace(serverId, id): self = .workspace(serverId: serverId, workspaceId: id)
    case let .bot(serverId, id): self = .bot(serverId: serverId, botId: id)
    case .archivedWorkspace, .newChat, .none: return nil
    }
  }

  var serverId: String {
    switch self {
    case let .session(serverId, _), let .workspace(serverId, _), let .bot(serverId, _): serverId
    }
  }
}

nonisolated enum WorkspaceDeckSlot: Hashable {
  case workspace(UUID)
  case session(UUID)
  case bot(UUID)
  case sharedChat
}
