import CodevisorProtocol
import Foundation

public struct ServerProjectGitBranch: Decodable, Equatable, Hashable, Sendable, Identifiable {
  public var remote: String
  public var branch: String
  public var isDefault: Bool

  public init(remote: String, branch: String, isDefault: Bool) {
    self.remote = remote
    self.branch = branch
    self.isDefault = isDefault
  }

  public var id: String { "\(remote)\u{0}\(branch)" }
  public var displayName: String { "\(remote)/\(branch)" }
  public var worktreeBase: ProjectWorktreeBase {
    ProjectWorktreeBase(remote: remote, branch: branch)
  }
}

private struct UpdateProjectWorktreeBaseBody: Encodable {
  var worktreeBase: ProjectWorktreeBase?

  private enum CodingKeys: String, CodingKey {
    case worktreeBase
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let worktreeBase {
      try container.encode(worktreeBase, forKey: .worktreeBase)
    } else {
      try container.encodeNil(forKey: .worktreeBase)
    }
  }
}

extension CodevisorServerClient {
  public func listProjectGitBranches(projectId: UUID) async throws -> [ServerProjectGitBranch] {
    try await get("/v1/projects/\(projectId.uuidString)/git/branches")
  }

  public func updateProjectWorktreeBase(
    id: UUID,
    worktreeBase: ProjectWorktreeBase?
  ) async throws -> ServerProject {
    try await send(
      "/v1/projects/\(id.uuidString)",
      method: "PATCH",
      body: UpdateProjectWorktreeBaseBody(worktreeBase: worktreeBase)
    )
  }
}
