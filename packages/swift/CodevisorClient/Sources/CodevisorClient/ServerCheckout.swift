import Foundation

public struct ServerCheckout: Codable, Equatable, Sendable {
  public var id: String
  public var serverId: String
  public var projectId: String
  public var path: String
  public var worktreeId: String?
  public var worktreeName: String?
  public var git: ServerWorkspaceGit?
  public var createdAt: String
  public var updatedAt: String?

  public init(
    id: String,
    serverId: String,
    projectId: String,
    path: String,
    worktreeId: String? = nil,
    worktreeName: String? = nil,
    git: ServerWorkspaceGit? = nil,
    createdAt: String,
    updatedAt: String? = nil
  ) {
    self.id = id
    self.serverId = serverId
    self.projectId = projectId
    self.path = path
    self.worktreeId = worktreeId
    self.worktreeName = worktreeName
    self.git = git
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
