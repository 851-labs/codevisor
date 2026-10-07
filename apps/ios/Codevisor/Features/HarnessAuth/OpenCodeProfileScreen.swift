import CodevisorCore
import CodevisorUI
import SwiftUI

/// One OpenCode profile: its providers, and using it for new chats.
struct OpenCodeProfileScreen: View {
  @Environment(AppEnvironment.self) private var environment
  let isShared: Bool

  let serverId: String
  let harness: ServerHarness
  @State private var account: ServerHarnessAccount
  let onChange: () -> Void
  let initialProviderId: String?
  let startsSignIn: Bool
  @State private var workingLabel: String?
  @State private var errorMessage: String?

  init(
    serverId: String,
    harness: ServerHarness,
    initialAccount: ServerHarnessAccount,
    isShared: Bool,
    initialProviderId: String? = nil, startsSignIn: Bool = false,
    onChange: @escaping () -> Void
  ) {
    self.serverId = serverId
    self.isShared = isShared
    self.harness = harness
    _account = State(initialValue: initialAccount)
    self.initialProviderId = initialProviderId
    self.startsSignIn = startsSignIn
    self.onChange = onChange
  }

  private var client: HarnessAccountsStore {
    HarnessAccountsStore(environment: environment, machineId: serverId, isShared: isShared)
  }

  var body: some View {
    HarnessProviderAccountsView(
      harness: harness, machineId: serverId, profile: account,
      request: startsSignIn || initialProviderId != nil
        ? HarnessMachineSignIn(profileId: account.id, providerId: initialProviderId) : nil
    ) { onChange() }
    .environment(\.sharedHarnessAccounts, isShared)
    .sheetStatus(workingLabel)
    .toolbar {
      if !account.isActive {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button("Use for New Chats", systemImage: "checkmark") { Task { await activate() } }
              .disabled(workingLabel != nil)
          } label: {
            Label("Profile Actions", systemImage: "ellipsis")
          }
        }
      }
      HarnessAccountsCloseToolbar()
    }
    .alert("OpenCode", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
    .navigationTitle(account.profileKind == "default" ? "Default Profile" : account.label)
    .navigationBarTitleDisplayMode(.inline)
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
  }

  private func activate() async {
    workingLabel = "Switching profile…"
    defer { workingLabel = nil }
    do {
      let accounts = try await client.activateHarnessAccount(harnessId: "opencode", accountId: account.id)
      if let updated = accounts.first(where: { $0.id == account.id }) { account = updated }
      onChange()
    } catch {
      errorMessage = serverErrorMessage(error)
    }
  }
}
