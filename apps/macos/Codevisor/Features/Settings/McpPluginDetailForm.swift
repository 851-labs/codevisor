import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

struct McpPluginDetailForm: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: McpFleetEntry
  let server: ServerMcpServer
  let machineId: String
  let plugins: PluginSettingsModel
  @State private var permissions = ComputerUsePermissionsModel(
    probes: AppPreview.isRunning ? .granted : .live)
  @State private var confirmingRemoval = false
  @State private var accounts: PluginAccountsModel?
  @State private var subscriptions: PluginSubscriptionsModel?
  @State private var removalError: String?

  private var model: McpGlobalModel { plugins.fleet }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: machineId)
  }

  var body: some View {
    Form {
      infoSection
      if let accounts { PluginAccountsSection(model: accounts) }
      McpMachinesSection(entry: entry, model: model, disabledReason: toggleDisabledReason)
      if isComputerUse {
        Section("Permissions") {
          ComputerUsePermissionRowsView(model: permissions, embedded: true)
        }
      }
      if let subscriptions { PluginSubscriptionsSection(model: subscriptions, chatTitle: chatTitle) }
      McpServerToolSections(server: server, client: client, isConnected: isConnected)
      if entry.canRemove { removeSection }
    }
    .formStyle(.grouped)
    .task(id: server.id) { await loadPluginDetails() }
    .onChange(of: permissions.allGranted) { _, granted in
      guard !granted else { return }
      disableComputerUseWithoutPermissions()
    }
    .confirmationDialog(
      "Remove \(entry.name)?", isPresented: $confirmingRemoval, titleVisibility: .visible
    ) {
      Button("Remove Plugin", role: .destructive) { Task { await remove() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("It will be removed from every machine.")
    }
  }

  private var infoSection: some View {
    Section {
      McpStatusRow(entry: entry, model: model)
      if isEditable {
        McpServerInlineEditor(server: server, callbackNote: callbackNote, save: save) { entries, isHTTP, onCommit in
          McpKeyValueEditor(
            entries: entries,
            nameHeading: isHTTP ? "Header" : "Variable",
            namePrompt: isHTTP ? "Authorization" : "DEBUG",
            valuePrompt: isHTTP ? "Bearer token" : "pw:mcp",
            emptyLabel: isHTTP ? "No custom headers" : "No environment variables",
            addLabel: isHTTP ? "Add Header" : "Add Environment Variable",
            onCommit: onCommit)
        }
      } else if showsConnectionRows {
        McpServerConnectionRows(server: server)
      }
    } footer: {
      if McpAccountButton.isShown(for: entry, model: model, in: environment) {
        SettingsListActions {
          McpAccountButton(entry: entry, model: model, onSignIn: signIn)
        }
      }
    }
  }

  private var removeSection: some View {
    Section {
    } footer: {
      SettingsListActions(message: removalError) {
        Button("Remove…", role: .destructive) { confirmingRemoval = true }
          .buttonStyle(.bordered)
          .help("Remove this plugin from every machine")
      }
    }
  }

  private var isComputerUse: Bool { entry.kind == "computerUse" }

  private var showsConnectionRows: Bool {
    !server.isBuiltIn && !server.isBundledPlugin
  }

  private var isEditable: Bool {
    entry.canEdit && !server.isBuiltIn && server.catalogId == nil
  }

  private var callbackNote: String {
    "With your own client ID, register each machine's Codevisor callback as a redirect URI with the provider. "
      + "This Mac's callback is \(LocalServerEndpoint.shared.mcpOAuthCallbackURL.absoluteString)."
  }

  private var isConnected: Bool {
    if case .ready = model.row(for: entry, on: machineId, in: environment)?.status { true } else { false }
  }

  private func toggleDisabledReason(_ rowMachineId: String) -> String? {
    guard isComputerUse, rowMachineId == CodevisorMachine.local.id, !permissions.allGranted else {
      return nil
    }
    return "Computer Use needs Accessibility and Screen Recording on this Mac."
  }

  private func disableComputerUseWithoutPermissions() {
    let localId = CodevisorMachine.local.id
    guard isComputerUse, model.row(for: entry, on: localId, in: environment)?.isOn == true else {
      return
    }
    Task { await model.setAvailability(false, of: entry, on: localId, in: environment) }
  }

  private func signIn(on signInMachineId: String) {
    guard let serverId = entry.idByMachine[signInMachineId] else { return }
    Task { await plugins.beginOAuth(serverId: serverId, machineId: signInMachineId, in: environment) }
  }

  private func loadPluginDetails() async {
    let accounts = PluginAccountsModel(server: server, client: client)
    let subscriptions = PluginSubscriptionsModel(serverId: server.id, client: client)
    self.accounts = accounts
    self.subscriptions = subscriptions
    await accounts.load()
    await subscriptions.load()
  }

  private func chatTitle(_ sessionId: String) -> String? {
    guard let id = UUID(uuidString: sessionId) else { return nil }
    return environment.projectList.session(id, serverId: machineId)?.title
  }

  private func save(_ body: UpdateMcpServerBody) async throws -> ServerMcpServer {
    let updated = try await client.updateMcpServer(id: server.id, request: body)
    await model.load(in: environment)
    if updated.authType == "oauth" && updated.connectionState == "needsAuthorization" {
      Task { await plugins.beginOAuth(serverId: server.id, machineId: machineId, in: environment) }
    }
    return updated
  }

  private func remove() async {
    do {
      try await client.removeMcpServer(id: server.id)
      removalError = nil
      SettingsRouter.shared.panePath.removeAll { $0 == .plugin(entry.name) }
      await model.load(in: environment)
    } catch {
      removalError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
