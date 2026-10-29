import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpPluginDetailView: View {
  let entryName: String
  let plugins: PluginSettingsModel

  private var model: McpGlobalModel { plugins.fleet }

  var body: some View {
    Group {
      if let entry = model.entry(named: entryName),
        let machineId = entry.machineId(preferring: CodevisorMachine.local.id),
        let server = entry.server(on: machineId)
      {
        McpPluginDetailForm(entry: entry, server: server, machineId: machineId, plugins: plugins)
      } else {
        unavailable
      }
    }
    .navigationTitle(entryName)
    .mcpFleetLiveUpdates(model)
    .pluginConnectErrorAlert(model)
  }

  private var unavailable: some View {
    Form {
      if model.isLoading {
        ProgressView().frame(maxWidth: .infinity)
      } else {
        ContentUnavailableView {
          Label("Plugin Unavailable", systemImage: "puzzlepiece.extension")
        } description: {
          Text("This plugin may have been removed.")
        } actions: {
          Button("Back to Plugins") { SettingsRouter.shared.panePath = [] }
        }
      }
    }
    .formStyle(.grouped)
  }
}
