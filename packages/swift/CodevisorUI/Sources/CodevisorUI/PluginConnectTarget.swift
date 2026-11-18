import CodevisorCore
import Foundation

public struct PluginConnectTarget: Identifiable {
  public let entry: ServerPluginCatalogEntry
  public let installed: ServerMcpServer?

  public var id: String { entry.id }

  public init(entry: ServerPluginCatalogEntry, installed: ServerMcpServer?) {
    self.entry = entry
    self.installed = installed
  }
}
