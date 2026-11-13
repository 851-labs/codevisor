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

  public func chats(ownedBy owners: Set<UUID>) -> [ChatSession] {
    sessions
      .filter { chat in !chat.isArchived && chat.ownerAgent.map { owners.contains($0.agentId) } == true }
      .sorted { $0.createdAt < $1.createdAt }
  }
}
