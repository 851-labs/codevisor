import CodevisorCore
import SwiftUI

public struct PluginSetupHost<AccountSheet: View>: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  @State private var model: PluginSetupModel
  let resolution: PluginSetupResolution?
  let machineId: String
  let inBotConversation: Bool
  let onDecline: () -> Void
  let accountSheet: (PluginAccountEditing, PluginAccountsModel) -> AccountSheet

  public init(
    request: ServerPluginSetupRequest,
    resolution: PluginSetupResolution?,
    machineId: String,
    client: any CodevisorServerClienting,
    inBotConversation: Bool,
    onDecline: @escaping () -> Void,
    @ViewBuilder accountSheet: @escaping (PluginAccountEditing, PluginAccountsModel) -> AccountSheet
  ) {
    _model = State(initialValue: PluginSetupModel(request: request, client: client))
    self.resolution = resolution
    self.machineId = machineId
    self.inBotConversation = inBotConversation
    self.onDecline = onDecline
    self.accountSheet = accountSheet
  }

  public var body: some View {
    PluginSetupCard(model: model, resolution: resolution, inBotConversation: inBotConversation, onDecline: onDecline)
      .task(id: refreshKey) { await refreshWhilePending() }
      .sheet(item: $model.installing) { entry in
        PluginInstallSheet(entry: entry) { try await model.install(values: $0) }
      }
      .sheet(item: $model.addingAccount, onDismiss: refresh) { editing in
        if let accounts = model.accounts { accountSheet(editing, accounts) }
      }
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
