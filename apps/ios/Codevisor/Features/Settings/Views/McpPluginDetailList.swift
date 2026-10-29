import CodevisorCore
import CodevisorUI
import SwiftUI

struct McpPluginDetailList: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let entry: McpFleetEntry
  let server: ServerMcpServer
  let machineId: String
  let model: McpGlobalModel
  @State private var confirmingRemoval = false
  @State private var accounts: PluginAccountsModel?
  @State private var subscriptions: PluginSubscriptionsModel?
  @State private var removalError: String?
  @State private var reporting = false
  @State private var confirmingBlock = false

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: machineId)
  }

  var body: some View {
    List {
      Section {
        McpStatusRow(entry: entry, model: model)
        if isEditable {
          McpServerInlineEditor(server: server, callbackNote: callbackNote, save: save)
        }
        if !server.isBuiltIn { PluginAgeRatingRow(subject: subject) }
      }
      McpMachinesSection(entry: entry, model: model)
      if let accounts { PluginAccountsSection(model: accounts) }
      if let subscriptions { PluginSubscriptionsSection(model: subscriptions, chatTitle: chatTitle) }
      McpServerToolSections(server: server, client: client, isConnected: isConnected)
      if let accounts { PluginAccountSignOutSection(model: accounts) }
      if summary.isSignedIn { signOutSection }
      if showsModeration || entry.canRemove { manageSection }
    }
    .toolbar {
      if summary.needsSignIn, let signInMachineId {
        SheetConfirmToolbarItem("Sign In") { signIn(on: signInMachineId) }
      }
    }
    .task(id: server.id) { await loadPluginDetails() }
    .sheet(isPresented: $reporting) {
      PluginReportSheet(subject: subject).environment(environment)
    }
    .pluginBlockConfirmation(subject: subject, isPresented: $confirmingBlock)
    .alert("Remove \(entry.name)?", isPresented: $confirmingRemoval) {
      Button("Remove", role: .destructive) { Task { await remove() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("It will be removed from every machine.")
    }
  }

  private var signOutSection: some View {
    Section {
      Button("Sign Out") { Task { await model.disconnect(entry, in: environment) } }
    }
  }

  private var manageSection: some View {
    Section {
      if showsModeration {
        Button("Report…") { reporting = true }
        PluginBlockMenuItem(subject: subject) { confirmingBlock = true }
      }
      if entry.canRemove {
        Button("Remove Plugin", role: .destructive) { confirmingRemoval = true }
          .foregroundStyle(.red)
      }
    } footer: {
      if let removalError { Text(removalError).foregroundStyle(.red) }
    }
  }

  private var summary: McpFleetSummary {
    McpFleetSummary(entry: entry, rows: model.rows(for: entry, in: environment))
  }

  private var signInMachineId: String? {
    entry.machineId(preferring: CodevisorMachine.local.id)
  }

  private var isEditable: Bool {
    entry.canEdit && !server.isBuiltIn && server.catalogId == nil
  }

  private var callbackNote: String {
    "With your own client ID, register each machine's Codevisor callback as a redirect URI with the provider. "
      + "On a Mac it's usually http://127.0.0.1:49361/v1/mcps/oauth/callback; that Mac's Plugins settings show the exact URL."
  }

  private var subject: PluginModerationSubject { PluginModerationSubject(server: server) }

  private var showsModeration: Bool {
    !server.isBuiltIn && !subject.isFirstParty
  }

  private var isConnected: Bool {
    if case .ready = model.row(for: entry, on: machineId, in: environment)?.status { true } else { false }
  }

  private func signIn(on signInMachineId: String) {
    guard let serverId = entry.idByMachine[signInMachineId] else { return }
    Task { await model.connect(serverId: serverId, on: signInMachineId, in: environment) }
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
    return environment.projectList.sessions.first { $0.id == id }?.title
  }

  private func save(_ body: UpdateMcpServerBody) async throws -> ServerMcpServer {
    let updated = try await client.updateMcpServer(id: server.id, request: body)
    await model.load(in: environment)
    if updated.authType == "oauth" && updated.connectionState == "needsAuthorization" {
      Task { await model.connect(serverId: server.id, on: machineId, in: environment) }
    }
    return updated
  }

  private func remove() async {
    do {
      try await client.removeMcpServer(id: server.id)
      removalError = nil
      dismiss()
      await model.load(in: environment)
    } catch {
      removalError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
