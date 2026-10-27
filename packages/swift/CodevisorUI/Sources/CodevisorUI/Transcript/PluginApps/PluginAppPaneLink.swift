import CodevisorCore
import Foundation
import TranscriptKit

public enum PluginAppPaneLink {
  public static func resource(for app: CodevisorExecutionApp, chatMachineId: String) -> PluginAppPaneResource {
    PluginAppPaneResource(
      viewId: app.viewId, machineId: app.owningMachineId(fallback: chatMachineId), serverId: app.serverId,
      serverName: app.serverName, toolName: app.toolName, resourceUri: app.resourceUri)
  }

  public static func app(from resource: PluginAppPaneResource) -> CodevisorExecutionApp {
    CodevisorExecutionApp(
      viewId: resource.viewId, machineId: resource.machineId, serverId: resource.serverId,
      serverName: resource.serverName, toolName: resource.toolName, resourceUri: resource.resourceUri)
  }
}
