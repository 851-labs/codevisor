import CodevisorCore
import Foundation

@MainActor
public final class PluginAppPaneModels {
  public static let shared = PluginAppPaneModels()

  private var models: [UUID: PluginAppPaneModel] = [:]

  public func model(
    for pane: PaneDescriptorState, fallbackMachineId: String, environment: AppEnvironment
  ) -> PluginAppPaneModel? {
    guard let resource = pane.pluginApp else { return nil }
    if let model = models[pane.id] { return model }

    let model = PluginAppPaneModel(
      paneId: pane.id, resource: resource, fallbackMachineId: fallbackMachineId,
      ownerChatSessionId: pane.ownerChatSessionId, environment: environment)
    models[pane.id] = model
    return model
  }

  public func existing(paneId: UUID) -> PluginAppPaneModel? {
    models[paneId]
  }

  public func remove(paneId: UUID) {
    models.removeValue(forKey: paneId)?.close()
  }
}
