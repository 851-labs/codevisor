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
