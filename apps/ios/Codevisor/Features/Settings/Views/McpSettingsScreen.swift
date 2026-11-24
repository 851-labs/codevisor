import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = McpGlobalModel()
  @State private var addingCustom = false
  @State private var showingCatalog = false
  @State private var openedPlugin: String?
  @State private var installed: ServerMcpServer?

  private var authoringMachineId: String { environment.machines.selectedMachineId }

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
          Button("Browse Plugins…") { showingCatalog = true }
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
    .sheet(isPresented: $addingCustom, onDismiss: { openInstalled(signingIn: true) }) {
      McpServerEditor(machineId: authoringMachineId) { try await add($0) }
        .environment(environment)
    }
    .sheet(isPresented: $showingCatalog, onDismiss: { openInstalled(signingIn: false) }) {
      PluginCatalogScreen(
        machineId: authoringMachineId,
        client: environment.machines.client(for: authoringMachineId),
        fleet: model,
        onInstalled: { installed = $0 })
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

  private func openInstalled(signingIn: Bool) {
    guard let installed else { return }

    self.installed = nil
    let machineId = authoringMachineId
    Task {
      await model.load(machineId, in: environment)
      openedPlugin = installed.name
      Task { await model.load(in: environment) }
      guard signingIn, installed.awaitsAuthorization else { return }

      await model.connect(serverId: installed.id, on: machineId, in: environment)
    }
  }

  private func add(_ values: McpFormValues) async throws {
    try await recordConsent(for: values)
    installed = try await environment.machines.client(for: authoringMachineId)
      .createMcpServer(values.createBody)
  }

  private func recordConsent(for values: McpFormValues) async throws {
    let subject = PluginModerationSubject(custom: values.customLocation, name: values.name)
    try await environment.pluginAccess.recordConsent(subject, metadata: PluginConsentMetadata(custom: subject))
  }
}
