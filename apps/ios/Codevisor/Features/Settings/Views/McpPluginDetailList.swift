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
  @State private var lists: PluginListsModel?
  @State private var removalError: String?

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: machineId)
  }

  var body: some View {
    List {
      if isEditable || !server.isBuiltIn {
        Section {
          if isEditable {
            McpServerInlineEditor(server: server, callbackNote: callbackNote, save: save)
          }
          if !server.isBuiltIn { PluginAgeRatingRow(subject: subject) }
        }
      }
      if let accounts {
        PluginAccountsSection(model: accounts)
      }
      McpAccountsSection(entry: entry, model: model)
      McpMachinesSection(entry: entry, model: model)
      if let lists { PluginListLinks(model: lists, server: server) }
      if entry.canRemove { manageSection }
    }
    .task(id: server.id) { await loadPluginDetails() }
    .task(id: "\(server.id)|\(isConnected)") { await lists?.loadTools(for: server) }
    .toolbar {
      if showsModeration {
        ToolbarItem(placement: .topBarTrailing) {
          PluginModerationMenu(subject: subject)
        }
      }
    }
    .alert("Remove \(entry.name)?", isPresented: $confirmingRemoval) {
      Button("Remove", role: .destructive) { Task { await remove() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("It will be removed from every machine.")
    }
  }

  private var manageSection: some View {
    Section {
      Button("Remove Plugin", role: .destructive) { confirmingRemoval = true }
        .foregroundStyle(.red)
    } footer: {
      if let removalError { Text(removalError).foregroundStyle(.red) }
    }
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

  private func loadPluginDetails() async {
    let accounts = PluginAccountsModel(server: server, client: client)
    let lists = PluginListsModel(serverId: server.id, client: client)
    self.accounts = accounts
    self.lists = lists
    await accounts.load()
    await lists.subscriptions.load()
    await lists.loadTools(for: server)
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
