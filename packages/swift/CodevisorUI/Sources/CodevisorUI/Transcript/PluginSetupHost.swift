import CodevisorCore
import SwiftUI

public struct PluginSetupHost<AccountSheet: View>: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  @State private var model: PluginSetupModel
  let resolution: PluginSetupResolution?
  let machineId: String
  let client: any CodevisorServerClienting
  let inBotConversation: Bool
  let onDecline: () -> Void
  let accountSheet: (PluginAccountEditing, PluginAccountsModel) -> AccountSheet

  public init(
    request: ServerPluginSetupRequest,
    resolution: PluginSetupResolution?,
    machineId: String,
    client: any CodevisorServerClienting,
    signInRoute: PluginSignInRoute,
    inBotConversation: Bool,
    onDecline: @escaping () -> Void,
    @ViewBuilder accountSheet: @escaping (PluginAccountEditing, PluginAccountsModel) -> AccountSheet
  ) {
    _model = State(initialValue: PluginSetupModel(request: request, client: client, signInRoute: signInRoute))
    self.resolution = resolution
    self.machineId = machineId
    self.client = client
    self.inBotConversation = inBotConversation
    self.onDecline = onDecline
    self.accountSheet = accountSheet
  }

  public var body: some View {
    PluginSetupCard(
      model: model, resolution: resolution, inBotConversation: inBotConversation, icon: AnyView(icon),
      onDecline: onDecline
    )
    .task(id: refreshKey) { await refreshWhilePending() }
    .sheet(item: $model.installing) { entry in
      PluginInstallSheet(entry: entry, client: client) { try await model.install(values: $0) }
    }
    .sheet(item: $model.addingAccount, onDismiss: refresh) { editing in
      if let accounts = model.accounts { accountSheet(editing, accounts) }
    }
  }

  private var icon: PluginCatalogIcon {
    let side = TranscriptInlineCardMetrics.iconSize
    if let server = model.server {
      return PluginCatalogIcon(
        pluginId: server.id, name: server.name, host: server.url.flatMap { URL(string: $0)?.host() },
        namespace: machineId, client: client, side: side)
    }
    if let entry = model.entry { return PluginCatalogIcon(entry: entry, client: client, side: side) }
    return PluginCatalogIcon(
      pluginId: model.request.plugin, name: model.request.name, host: nil, namespace: machineId, client: client,
      side: side)
  }

  private var refreshKey: [UInt64] {
    [environment?.pluginAccountsRevision ?? 0, environment?.mcpStateRevision(for: machineId) ?? 0]
  }

  private func refreshWhilePending() async {
    guard resolution == nil else { return }
    await model.refresh()
  }

  private func refresh() {
    Task { await refreshWhilePending() }
  }
}
