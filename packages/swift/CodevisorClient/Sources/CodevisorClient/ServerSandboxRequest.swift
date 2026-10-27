import Foundation

public struct ServerSandboxRequest: Encodable, Equatable, Sendable {
  public var id: String
  public var provider: String
  public var projectId: UUID
  public var workspaceId: UUID?
  public var harnessId: String?

  public init(id: String, provider: String, projectId: UUID, workspaceId: UUID?, harnessId: String?) {
    self.id = id
    self.provider = provider
    self.projectId = projectId
    self.workspaceId = workspaceId
    self.harnessId = harnessId
  }

  private enum CodingKeys: String, CodingKey {
    case id, provider, projectId, workspaceId, defersWorkspace, harnessId
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(provider, forKey: .provider)
    try container.encode(projectId.uuidString, forKey: .projectId)
    try container.encodeIfPresent(workspaceId?.uuidString, forKey: .workspaceId)
    if workspaceId == nil { try container.encode(true, forKey: .defersWorkspace) }
    try container.encodeIfPresent(harnessId, forKey: .harnessId)
  }
}
