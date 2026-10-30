import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = McpGlobalModel()
  @State private var addingCustom = false
  @State private var showingCatalog = false
  @State private var openedPlugin: String?

  private var authoringMachineId: String {
    let selected = environment.machines.selectedMachineId
    guard !supportsPlugins(selected) else { return selected }
    return environment.machines.allMachines.map(\.id).first(where: supportsPlugins) ?? selected
  }

  var body: some View {
    List {
      Section("Built-in Tools") {
        fleetSection(builtIn: true)
      }
      Section("Plugins") {
        fleetSection(builtIn: false)
      }
      Section {
        NavigationLink("Blocked Publishers") { PluginBlockedPublishersView() }
      }
    }
    .navigationTitle("Plugins")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          if supportsCatalog {
            Button("Browse Plugins…") { showingCatalog = true }
          }
          Button("Add MCP…") { addingCustom = true }
        } label: {
          Label("Add", systemImage: "plus")
        }
      }
    }
    .mcpFleetLiveUpdates(model)
    .navigationDestination(item: $openedPlugin) { name in
      McpPluginDetailScreen(entryName: name, model: model)
    }
    .sheet(isPresented: $addingCustom) {
      McpServerEditor(machineId: authoringMachineId) { try await add($0) }
        .environment(environment)
    }
    .sheet(isPresented: $showingCatalog) {
      PluginCatalogScreen(
        client: environment.machines.client(for: authoringMachineId),
        fleet: model,
        onInstalled: { didAdd($0, on: authoringMachineId) })
    }
    .pluginErrorsAlert(model)
  }

  private func fleetSection(builtIn: Bool) -> some View {
    McpFleetSection(model: model, builtIn: builtIn) { entry in
      NavigationLink {
        McpPluginDetailScreen(entryName: entry.name, model: model)
      } label: {
        McpFleetEntryLabel(entry: entry, model: model) { McpEntryIcon(entry: entry) }
      }
    }
  }

  private var supportsCatalog: Bool {
    supportsPlugins(authoringMachineId)
  }

  private func supportsPlugins(_ machineId: String) -> Bool {
    environment.machines.statusByMachineId[machineId]?.supportsPlugins == true
  }

  private func didAdd(_ created: ServerMcpServer, on machineId: String) {
    Task {
      await model.load(in: environment)
      openedPlugin = created.name
      guard created.awaitsAuthorization else { return }

      await model.connect(serverId: created.id, on: machineId, in: environment)
    }
  }

  private func add(_ values: McpFormValues) async throws {
    try await recordConsent(for: values)
    let created = try await environment.machines.client(for: authoringMachineId)
      .createMcpServer(values.createBody)
    didAdd(created, on: authoringMachineId)
  }

  private func recordConsent(for values: McpFormValues) async throws {
    let subject = PluginModerationSubject(custom: values.customLocation, name: values.name)
    try await environment.pluginAccess.recordConsent(subject, metadata: PluginConsentMetadata(custom: subject))
  }
}
