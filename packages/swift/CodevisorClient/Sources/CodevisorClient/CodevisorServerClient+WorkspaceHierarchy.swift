import Foundation

/// One change to where a workspace sits: its owner, its tab group in the
/// owner's tab bar, or its sidebar folder.
public enum WorkspaceHierarchyChange: Codable, Equatable, Sendable {
  /// Makes the workspace owned by another one; nil promotes it to the top
  /// level.
  case owner(UUID?)
  /// Moves its tab group in the owner's tab bar; the latest move wins.
  case groupPosition(String)
  case groupCollapsed(Bool)
  /// Files it into a sidebar folder; nil unfiles it.
  case folder(UUID?)
}

/// The PATCH body for one hierarchy change. A cleared owner or folder must
/// reach the server as an explicit `null`, which synthesized coding omits.
private struct WorkspaceHierarchyBody: Encodable {
  let change: WorkspaceHierarchyChange

  private enum CodingKeys: String, CodingKey {
    case parentWorkspaceId, parentTabPosition, groupCollapsed, folderId
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch change {
    case let .owner(owner):
      if let owner {
        try container.encode(owner.uuidString, forKey: .parentWorkspaceId)
      } else {
        try container.encodeNil(forKey: .parentWorkspaceId)
      }
    case let .groupPosition(position):
      try container.encode(position, forKey: .parentTabPosition)
    case let .groupCollapsed(collapsed):
      try container.encode(collapsed, forKey: .groupCollapsed)
    case let .folder(folder):
      if let folder {
        try container.encode(folder.uuidString, forKey: .folderId)
      } else {
        try container.encodeNil(forKey: .folderId)
      }
    }
  }
}

extension CodevisorServerClient {
  public func updateWorkspaceHierarchy(id: UUID, _ change: WorkspaceHierarchyChange) async throws {
    try await sendNoResponse(
      "/v1/workspaces/\(id.uuidString)", method: "PATCH", body: WorkspaceHierarchyBody(change: change))
  }
}
