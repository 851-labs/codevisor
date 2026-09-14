import Foundation

private struct RenameWorkspaceBody: Encodable {
  var name: String
  var hasCustomName: Bool
}

extension CodevisorServerClient {
  /// A partial update preserves archive state and other devices' metadata.
  public func renameWorkspace(id: UUID, name: String, hasCustomName: Bool) async throws {
    try await sendNoResponse(
      "/v1/workspaces/\(id.uuidString)",
      method: "PATCH",
      body: RenameWorkspaceBody(name: name, hasCustomName: hasCustomName)
    )
  }
}
