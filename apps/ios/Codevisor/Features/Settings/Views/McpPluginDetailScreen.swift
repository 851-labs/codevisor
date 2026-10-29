import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpPluginDetailScreen: View {
  @Environment(AppEnvironment.self) private var environment
  let entryName: String
  let model: McpGlobalModel

  var body: some View {
    Group {
      if let entry = model.entry(named: entryName),
        let machineId = entry.machineId(preferring: environment.machines.selectedMachineId),
        let server = entry.server(on: machineId)
      {
        McpPluginDetailList(entry: entry, server: server, machineId: machineId, model: model)
      } else {
        ContentUnavailableView(
          "Plugin Unavailable", systemImage: "puzzlepiece.extension",
          description: Text("This plugin may have been removed."))
      }
    }
    .navigationTitle(entryName)
    .navigationBarTitleDisplayMode(.inline)
    .mcpFleetLiveUpdates(model)
    .pluginErrorsAlert(model, includesActionErrors: false)
  }
}
