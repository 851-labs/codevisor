import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var showingCustom = false

  let plugins: PluginSettingsModel

  private var model: McpGlobalModel { plugins.fleet }

  private var localClient: any CodevisorServerClienting {
    environment.machines.client(for: CodevisorMachine.local.id)
  }

  var body: some View {
    Form {
      Section("Built-in Tools") {
        fleetSection(builtIn: true)
      }
      Section {
        fleetSection(builtIn: false)
      } header: {
        Text("Plugins")
      } footer: {
        SettingsListActions(message: model.actionError) {
          PluginAddMenu(
            canBrowse: supportsCatalog,
            onBrowse: { SettingsRouter.shared.panePath.append(.pluginCatalog) },
            onAddCustom: { showingCustom = true })
        }
      }
    }
    .formStyle(.grouped)
    .pluginConnectErrorAlert(model)
    .mcpFleetLiveUpdates(model)
    .sheet(isPresented: $showingCustom) {
      McpServerEditorSheet { values in
        try await recordConsent(for: values)
        plugins.didInstall(try await localClient.createMcpServer(values.createBody), in: environment)
      }
    }
  }

  private func fleetSection(builtIn: Bool) -> some View {
    McpFleetSection(model: model, builtIn: builtIn) { entry in
      NavigationLink(value: SettingsPaneRoute.plugin(entry.name)) {
        McpFleetEntryLabel(entry: entry, model: model) { McpEntryIcon(entry: entry) }
      }
    }
  }

  private var supportsCatalog: Bool {
    environment.machines.statusByMachineId[CodevisorMachine.local.id]?.supportsPlugins == true
  }

  private func recordConsent(for values: McpFormValues) async throws {
    let subject = PluginModerationSubject(custom: values.customLocation, name: values.name)
    try await environment.pluginAccess.recordConsent(subject, metadata: PluginConsentMetadata(custom: subject))
  }
}

#Preview("Plugins Settings") {
  McpSettingsView(plugins: PluginSettingsModel())
    .environment(AppEnvironment.preview())
    .frame(width: 560, height: 460)
}
