import CodevisorCore
import CodevisorUI
import Observation

@Observable
final class PluginSettingsModel {
  let fleet = McpGlobalModel()
  @ObservationIgnored private var catalogModel: PluginCatalogModel?

  func catalog(using client: any CodevisorServerClienting) -> PluginCatalogModel {
    if let catalogModel { return catalogModel }

    let created = PluginCatalogModel(client: client)
    catalogModel = created
    return created
  }

  func didInstall(_ server: ServerMcpServer, in environment: AppEnvironment) {
    Task {
      await fleet.load(in: environment)
      guard server.awaitsAuthorization else { return }

      await beginOAuth(serverId: server.id, machineId: CodevisorMachine.local.id, in: environment)
    }
  }

  func beginOAuth(serverId: String, machineId: String, in environment: AppEnvironment) async {
    await fleet.connect(serverId: serverId, on: machineId, in: environment)
  }
}
