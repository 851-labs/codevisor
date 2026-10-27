import Foundation

public struct ServerSandboxRequest: Encodable, Equatable, Sendable {
  public var id: String
  public var profileId: String
  public var projectId: UUID
  public var projectName: String?
  public var repoUrl: String?
  public var workspaceId: UUID?
  public var harnessId: String?

  public init(
    id: String,
    profileId: String,
    projectId: UUID,
    projectName: String? = nil,
    repoUrl: String? = nil,
    workspaceId: UUID?,
    harnessId: String?
  ) {
    self.id = id
    self.profileId = profileId
    self.projectId = projectId
    self.projectName = projectName
    self.repoUrl = repoUrl
    self.workspaceId = workspaceId
    self.harnessId = harnessId
  }

  private enum CodingKeys: String, CodingKey {
    case id, profileId, projectId, projectName, repoUrl, workspaceId, defersWorkspace, harnessId
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(profileId, forKey: .profileId)
    try container.encode(projectId.uuidString, forKey: .projectId)
    try container.encodeIfPresent(projectName, forKey: .projectName)
    try container.encodeIfPresent(repoUrl, forKey: .repoUrl)
    try container.encodeIfPresent(workspaceId?.uuidString, forKey: .workspaceId)
    if workspaceId == nil { try container.encode(true, forKey: .defersWorkspace) }
    try container.encodeIfPresent(harnessId, forKey: .harnessId)
  }
}
