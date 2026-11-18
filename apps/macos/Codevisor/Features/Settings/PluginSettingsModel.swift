import CodevisorCore
import CodevisorUI
import Observation

@Observable
final class PluginSettingsModel {
  let fleet = McpGlobalModel()
  @ObservationIgnored private var catalogModel: PluginCatalogModel?
  @ObservationIgnored private var listModels: [String: PluginListsModel] = [:]

  func catalog(using client: any CodevisorServerClienting) -> PluginCatalogModel {
    if let catalogModel { return catalogModel }

    let created = PluginCatalogModel(client: client)
    catalogModel = created
    return created
  }

  func installedPlugin(named name: String) -> InstalledPlugin? {
    guard let entry = fleet.entry(named: name),
      let machineId = entry.machineId(preferring: CodevisorMachine.local.id),
      let server = entry.server(on: machineId)
    else { return nil }
    return InstalledPlugin(entry: entry, machineId: machineId, server: server)
  }

  func lists(serverId: String, machineId: String, client: any CodevisorServerClienting) -> PluginListsModel {
    let key = "\(machineId)/\(serverId)"
    if let model = listModels[key] { return model }

    let created = PluginListsModel(serverId: serverId, client: client)
    listModels[key] = created
    return created
  }

  func didInstall(_ server: ServerMcpServer, in environment: AppEnvironment) {
    Task {
      await fleet.load(CodevisorMachine.local.id, in: environment)
      SettingsRouter.shared.panePath = [.plugin(server.name)]
      await fleet.load(in: environment)
    }
  }

  func beginOAuth(serverId: String, machineId: String, in environment: AppEnvironment) async {
    await fleet.connect(serverId: serverId, on: machineId, in: environment)
  }
}
