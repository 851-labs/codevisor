import Foundation

private struct ReorderWorkspaceBody: Encodable {
  struct Order: Encodable {
    var position: String
    var expectedRevision: Int
  }
  var sidebarOrder: Order
}

extension CodevisorServerClient {
  public func reorderWorkspace(id: UUID, position: String, expectedRevision: Int) async throws -> ServerWorkspace {
    try await send(
      "/v1/workspaces/\(id.uuidString)", method: "PATCH",
      body: ReorderWorkspaceBody(sidebarOrder: .init(position: position, expectedRevision: expectedRevision))
    )
  }
}

private struct MovePaneBody: Encodable {
  var position: String
}

extension CodevisorServerClient {
  /// Moves one tab in its workspace's shared tab order.
  public func moveWorkspacePane(workspaceId: UUID, paneId: UUID, position: String) async throws {
    let _: ServerWorkspacePane = try await send(
      "/v1/workspaces/\(workspaceId.uuidString)/panes/\(paneId.uuidString)", method: "PATCH",
      body: MovePaneBody(position: position)
    )
  }
}
