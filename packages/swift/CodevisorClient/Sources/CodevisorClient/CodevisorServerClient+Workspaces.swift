import Foundation

private struct UpdateWorkspaceBody: Encodable {
  var isArchived: Bool
}

private struct RenameWorkspaceBody: Encodable {
  var name: String
  var hasCustomName: Bool
}

extension CodevisorServerClient {
  public func setWorkspaceArchived(id: UUID, isArchived: Bool) async throws {
    do {
      try await sendNoResponse(
        "/v1/workspaces/\(id.uuidString)",
        method: "PATCH",
        body: UpdateWorkspaceBody(isArchived: isArchived)
      )
    } catch CodevisorServerClientError.httpStatus(404, _) {
      return
    } catch CodevisorServerClientError.httpStatus(405, _) {
      return
    }
  }

  public func renameWorkspace(id: UUID, name: String, hasCustomName: Bool) async throws {
    try await sendNoResponse(
      "/v1/workspaces/\(id.uuidString)",
      method: "PATCH",
      body: RenameWorkspaceBody(name: name, hasCustomName: hasCustomName)
    )
  }
}
