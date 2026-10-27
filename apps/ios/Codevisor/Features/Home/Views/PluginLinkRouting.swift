import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginLinkRouting: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.openURL) private var openURL
  @Binding var catalogId: String?
  @State private var entry: ServerPluginCatalogEntry?
  @State private var errorMessage: String?

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: environment.defaultComposerServerId)
  }

  func body(content: Content) -> some View {
    content
      .task(id: catalogId) { await open() }
      .sheet(item: $entry) { entry in
        PluginInstallSheet(entry: entry) { values in try await install(entry, values: values) }
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

  private func install(_ entry: ServerPluginCatalogEntry, values: [String: ServerConfigFieldValue]) async throws {
    let catalog = PluginCatalogModel(client: client)
    let installed = try await catalog.install(entry, values: values, access: environment.pluginAccess)
    guard installed.awaitsAuthorization else { return }

    let flow = try await client.startMcpOAuth(id: installed.id)
    if let url = URL(string: flow.authorizationUrl) { openURL(url) }
  }
}
