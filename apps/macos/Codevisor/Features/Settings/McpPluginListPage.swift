import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpPluginListPage: View {
  @Environment(AppEnvironment.self) private var environment
  let entryName: String
  let page: PluginListPage
  let plugins: PluginSettingsModel

  var body: some View {
    Group {
      if let plugin = plugins.installedPlugin(named: entryName) {
        content(for: plugin)
      } else {
        McpPluginUnavailableForm(isLoading: plugins.fleet.isLoading)
      }
    }
    .navigationTitle(page.title)
  }

  @ViewBuilder
  private func content(for plugin: InstalledPlugin) -> some View {
    let lists = plugins.lists(
      serverId: plugin.server.id, machineId: plugin.machineId,
      client: environment.machines.client(for: plugin.machineId))
    if page == .automations {
      PluginAutomationsPage(model: lists.subscriptions, machineId: plugin.machineId)
    } else {
      PluginCapabilityListPage(page, lists: lists.lists(for: plugin.server), isLoading: lists.isLoadingTools)
    }
  }
}
