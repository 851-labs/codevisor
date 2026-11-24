import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginLinkRouting: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var catalogId: String?
  @State private var entry: ServerPluginCatalogEntry?
  @State private var errorMessage: String?
  @State private var fleet = McpGlobalModel()

  private var machineId: String { environment.defaultComposerServerId }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: machineId)
  }

  func body(content: Content) -> some View {
    content
      .task(id: catalogId) { await open() }
      .sheet(item: $entry) { entry in
        PluginConnectSheet(entry: entry, client: client, host: host(for: entry))
          .environment(environment)
      }
      .alert(
        "Plugin unavailable",
        isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK") { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
      .pluginErrorsAlert(fleet)
  }

  private func open() async {
    guard let catalogId else { return }
    defer { self.catalogId = nil }

    do {
      entry = try await client.pluginCatalogEntry(id: catalogId)
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func host(for entry: ServerPluginCatalogEntry) -> PluginConnectHost {
    fleet.connectHost(
      on: machineId, in: environment,
      install: { values, authType in
        try await PluginCatalogModel(client: client).install(
          entry, values: values, authType: authType, access: environment.pluginAccess)
      },
      didInstall: { _ in }
    )
  }
}
