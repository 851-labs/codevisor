import Foundation

extension AppEnvironment {
  public func pluginStateRevision(for serverId: String) -> UInt64 {
    pluginStateRevisions[serverId, default: 0]
  }

  public func pluginStateDidChange(onServer serverId: String) {
    pluginStateRevisions[serverId, default: 0] &+= 1
  }

  public func pluginUpdateRevision(forServer serverId: String, pluginId: String) -> UInt64 {
    pluginUpdateRevisions[pluginUpdateKey(serverId: serverId, pluginId: pluginId), default: 0]
  }

  public func pluginDidUpdate(onServer serverId: String, pluginId: String) {
    pluginUpdateRevisions[pluginUpdateKey(serverId: serverId, pluginId: pluginId), default: 0] &+= 1
  }

  private func pluginUpdateKey(serverId: String, pluginId: String) -> String {
    "\(serverId)|\(pluginId)"
  }
}
