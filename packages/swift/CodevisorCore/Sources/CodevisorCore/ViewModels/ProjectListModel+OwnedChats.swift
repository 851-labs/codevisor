import Foundation

extension ProjectListModel {
  public func owningWorkspaceId(of session: ChatSession) -> UUID? {
    var current = session
    var seen: Set<UUID> = [session.id]
    while let owner = current.ownerAgent, seen.insert(owner.agentId).inserted {
      if let workspaceId = workspaceId(forSession: owner.agentId) { return workspaceId }
      guard let next = sessions.first(where: { $0.id == owner.agentId }) else { return nil }
      current = next
    }
    return nil
  }

  public func parent(of chat: ChatSession) -> ChatSession? {
    guard let parent = chat.parentAgent else { return nil }
    return sessions.first { $0.id == parent.agentId && !$0.isArchived }
  }

  public func children(of chat: ChatSession) -> [ChatSession] {
    sessions
      .filter { !$0.isArchived && $0.parentAgent?.agentId == chat.id }
      .sorted { $0.createdAt < $1.createdAt }
  }
}
