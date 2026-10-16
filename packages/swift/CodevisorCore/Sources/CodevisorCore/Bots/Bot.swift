import Foundation

public struct Bot: Identifiable, Hashable, Sendable {
  public let serverId: String
  public let id: UUID
  public let sessionId: UUID
  public let workspaceId: UUID
  public let projectId: UUID
  public let record: ServerBot

  public init?(serverId: String, record: ServerBot) {
    guard let id = UUID(uuidString: record.id),
      let sessionId = UUID(uuidString: record.sessionId),
      let workspaceId = UUID(uuidString: record.workspaceId),
      let projectId = UUID(uuidString: record.projectId)
    else { return nil }
    self.serverId = serverId
    self.id = id
    self.sessionId = sessionId
    self.workspaceId = workspaceId
    self.projectId = projectId
    self.record = record
  }

  public var name: String { record.name }
  public var symbolName: String { BotIcon(resolving: record.symbolName).systemImage }
  public var harnessId: String { record.harnessId }
  public var rootPath: String { record.rootPath }
  public var sourceProjectIds: [String] { record.projects.map(\.projectId) }
}
