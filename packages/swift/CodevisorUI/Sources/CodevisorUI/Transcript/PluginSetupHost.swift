import CodevisorCore
import SwiftUI

public struct PluginSetupHost<AccountSheet: View, GuideSheet: View>: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  @State private var model: PluginSetupModel
  let request: ServerPluginSetupRequest
  let isConnected: Bool
  let machineId: String
  let client: any CodevisorServerClienting
  let inBotConversation: Bool
  let accountSheet: (PluginAccountEditing, PluginAccountsModel) -> AccountSheet
  let guideSheet: (PluginAccountGuideModel, @escaping () async -> Void) -> GuideSheet

  public init(
    request: ServerPluginSetupRequest,
    isConnected: Bool,
    machineId: String,
    client: any CodevisorServerClienting,
    signInRoute: PluginSignInRoute,
    inBotConversation: Bool,
    @ViewBuilder accountSheet: @escaping (PluginAccountEditing, PluginAccountsModel) -> AccountSheet,
    @ViewBuilder guideSheet: @escaping (PluginAccountGuideModel, @escaping () async -> Void) -> GuideSheet
  ) {
    _model = State(
      initialValue: PluginSetupModel(
        request: request, client: client, signInRoute: signInRoute,
        opensConnectSheet: Self.opensConnectSheet(for: signInRoute)))
    self.request = request
    self.isConnected = isConnected
    self.machineId = machineId
    self.client = client
    self.inBotConversation = inBotConversation
    self.accountSheet = accountSheet
    self.guideSheet = guideSheet
  }

  public var body: some View {
    PluginSetupCard(
      model: model, request: request, isConnected: isConnected, inBotConversation: inBotConversation,
      icon: AnyView(icon)
    )
    .task(id: refreshKey) { await refreshWhilePending() }
    .modifier(PluginSetupConnectSheet(model: model, client: client))
    .sheet(item: $model.installing) { entry in
      PluginInstallSheet(entry: entry, client: client) { try await model.install(values: $0) }
    }
    .sheet(item: $model.addingAccount, onDismiss: refresh) { editing in
      if let accounts = model.accounts { accountSheet(editing, accounts) }
    }
    .sheet(item: $model.guiding, onDismiss: refresh) { guide in
      guideSheet(guide) { await model.refresh() }
    }
    .alert("Couldn’t set up \(model.request.name)", isPresented: showsError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private static func opensConnectSheet(for route: PluginSignInRoute) -> Bool {
    #if os(macOS)
      if case .thisMachine = route { return true }
    #endif
    return false
  }

  private var showsError: Binding<Bool> {
    Binding(
      get: { model.errorMessage != nil && !isConnected },
      set: { shown in
        if !shown { model.errorMessage = nil }
      })
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
    guard !isConnected else { return }
    await model.refresh()
  }

  private func refresh() {
    Task { await refreshWhilePending() }
  }
}
