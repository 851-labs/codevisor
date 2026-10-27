import Foundation

public struct PluginAppPaneResource: Codable, Equatable, Hashable, Sendable {
  public var viewId: String
  public var machineId: String?
  public var serverId: String
  public var serverName: String
  public var toolName: String
  public var resourceUri: String

  public init(
    viewId: String, machineId: String?, serverId: String, serverName: String, toolName: String, resourceUri: String
  ) {
    self.viewId = viewId
    self.machineId = machineId
    self.serverId = serverId
    self.serverName = serverName
    self.toolName = toolName
    self.resourceUri = resourceUri
  }
}
