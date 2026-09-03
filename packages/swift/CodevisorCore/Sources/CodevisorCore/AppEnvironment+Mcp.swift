import Foundation

/// MCP invalidation for machine-scoped consumers (the MCP settings panes).
/// MachineController bridges `mcp.updated` events into `mcpStateDidChange`;
/// views observe `mcpStateRevision(for:)` and refetch that machine's server
/// list, so a connection settling or an OAuth expiry shows up live instead
/// of on the next pane visit.
extension AppEnvironment {
  /// The current MCP-state invalidation token for a machine.
  public func mcpStateRevision(for serverId: String) -> UInt64 {
    mcpStateRevisions[serverId, default: 0]
  }

  /// Publishes that an `mcp.updated` event changed a machine's MCP state.
  public func mcpStateDidChange(onServer serverId: String) {
    mcpStateRevisions[serverId, default: 0] &+= 1
  }
}
