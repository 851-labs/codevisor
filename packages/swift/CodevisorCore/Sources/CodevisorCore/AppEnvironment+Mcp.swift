import Foundation

extension AppEnvironment {
  public func mcpStateRevision(for serverId: String) -> UInt64 {
    mcpStateRevisions[serverId, default: 0]
  }

  public func mcpStateDidChange(onServer serverId: String) {
    mcpStateRevisions[serverId, default: 0] &+= 1
  }
}
