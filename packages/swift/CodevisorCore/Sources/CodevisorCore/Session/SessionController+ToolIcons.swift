import Foundation

extension SessionController {
  /// Tool-call artwork from the machine that ran the session, through its
  /// authenticated client: favicons and MCP server icons, resolved and
  /// cached there.
  public func toolIconData(_ request: ServerToolIconRequest) async throws -> Data {
    guard let serverClient else { throw SessionControllerError.serverUnavailable }
    return try await serverClient.toolIcon(request)
  }

  /// Icons are per machine: an MCP server id names a server on one machine.
  public var toolIconCacheNamespace: String { "\(project.serverId)" }
}
