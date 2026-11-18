import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpPluginDetailView: View {
  let entryName: String
  let plugins: PluginSettingsModel

  private var model: McpGlobalModel { plugins.fleet }

  var body: some View {
    Group {
      if let plugin = plugins.installedPlugin(named: entryName) {
        McpPluginDetailForm(
          entry: plugin.entry, server: plugin.server, machineId: plugin.machineId, plugins: plugins)
      } else {
        McpPluginUnavailableForm(isLoading: model.isLoading)
      }
    }
    .navigationTitle(entryName)
    .mcpFleetLiveUpdates(model)
    .pluginConnectErrorAlert(model)
  }
}
