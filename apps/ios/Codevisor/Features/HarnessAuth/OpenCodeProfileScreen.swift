import CodevisorCore
import CodevisorUI
import SwiftUI

struct OpenCodeProfileScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let isShared: Bool
  let machineSignIn: (@MainActor (HarnessMachineSignIn) -> Void)?

  let serverId: String
  let harness: ServerHarness
  @State private var account: ServerHarnessAccount
  let onChange: () -> Void
  let initialProviderId: String?
  let startsSignIn: Bool
  @State private var pendingMachineSignIn: HarnessMachineSignIn?
  @State private var didOpenRequestedProvider = false

  @State private var providers: [ServerOpenCodeAuthProvider] = []
  @State private var isLoading = true
  @State private var workingLabel: String?
  private var isWorking: Bool { workingLabel != nil }
  @State private var errorMessage: String?
  @State private var setupProvider: OpenCodeProviderSetupRequest?

  init(
    serverId: String,
    harness: ServerHarness,
    initialAccount: ServerHarnessAccount,
    isShared: Bool,
    machineSignIn: (@MainActor (HarnessMachineSignIn) -> Void)?,
    initialProviderId: String? = nil, startsSignIn: Bool = false,
    onChange: @escaping () -> Void
  ) {
    self.serverId = serverId
    self.isShared = isShared
    self.machineSignIn = machineSignIn
    self.harness = harness
    _account = State(initialValue: initialAccount)
    self.initialProviderId = initialProviderId
    self.startsSignIn = startsSignIn
    self.onChange = onChange
  }

  private var client: HarnessAccountsStore {
    HarnessAccountsStore(environment: environment, machineId: serverId, isShared: isShared)
  }

  private var configuredProviders: [ServerOpenCodeAuthProvider] {
    providers.filter {
      $0.credentialType != nil && (isShared || account.profileKind != "default" || $0.credentialType == "oauth")
    }
  }

  var body: some View {
    Group {
      if isLoading && providers.isEmpty {
        SheetLoadingView("Loading providers…")
      } else if providers.isEmpty, let errorMessage {
        ContentUnavailableView {
          Label("Couldn't Load Accounts", systemImage: "exclamationmark.triangle")
        } description: {
          Text(errorMessage)
        } actions: {
          Button("Retry") { Task { await load() } }
        }
      } else if configuredProviders.isEmpty && !hasInheritedProviders {
        HarnessSignInInvitation(harnessId: harness.id, harnessName: harness.name, errorMessage: errorMessage) {
          Button("Sign In", systemImage: "plus") {
            setupProvider = OpenCodeProviderSetupRequest(providerId: nil)
          }
          .disabled(isLoading || providers.isEmpty || isWorking)
        }
      } else {
        providerList
      }
    }
    .sheetStatus(workingLabel)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if !configuredProviders.isEmpty || hasInheritedProviders {
          Button("Add Provider", systemImage: "plus") {
            setupProvider = OpenCodeProviderSetupRequest(providerId: nil)
          }.labelStyle(.iconOnly).disabled(isLoading || providers.isEmpty || isWorking)
        }
      }
      if !account.isActive {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button("Use for New Chats", systemImage: "checkmark") { Task { await activate() } }
              .disabled(isWorking)
          } label: {
            Label("Profile Actions", systemImage: "ellipsis")
          }
        }
      }
      HarnessAccountsCloseToolbar()
    }
    .navigationTitle(profileName)
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
    .onChange(of: environment.configSync.revisionsByNamespace[HarnessSharedCredentials.namespace]) { _, _ in
      if isShared { Task { await load() } }
    }
    .sheet(
      item: $setupProvider,
      onDismiss: {
        if let pendingMachineSignIn {
          self.pendingMachineSignIn = nil
          machineSignIn?(pendingMachineSignIn)
        }
      }
    ) { request in
      OpenCodeProviderSetupSheet(
        serverId: serverId,
        accountId: account.id,
        providers: providers,
        initialProviderId: request.providerId,
        onComplete: {
          Task {
            await load()
            onChange()
          }
        }
      )
      .environment(\.sharedHarnessAccounts, isShared)
      .environment(
        \.harnessMachineSignIn,
        { request in
          pendingMachineSignIn = request
          setupProvider = nil
        })
    }
  }

  private var hasInheritedProviders: Bool {
    !isShared && account.profileKind == "default"
      && ((try? HarnessSharedCredentials.opencode.credentials(
        from: HarnessSharedCredentials.opencode.content(in: environment.configSync)
      ).isEmpty) == false)
  }

  private var providerList: some View {
    List {
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(theme.statusError)
        }
      }

      Section("Providers") {
        if !isShared, account.profileKind == "default" {
          HarnessSharedAccountRows(source: .opencode, excludingProviderIds: Set(configuredProviders.map(\.id)))
        }
        ForEach(configuredProviders) { provider in
          Button {
            setupProvider = OpenCodeProviderSetupRequest(providerId: provider.id)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "key.fill")
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22)
              VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).foregroundStyle(Color.primary)
                Text(credentialDescription(provider.credentialType))
                  .font(.footnote)
                  .foregroundStyle(theme.textSecondary)
              }
              Spacer()
              Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", systemImage: "trash", role: .destructive) { Task { await remove(provider) } }.labelStyle(
              .iconOnly)
          }
        }

      }
    }
  }

  private var profileName: String {
    account.profileKind == "default" ? "Default Profile" : account.label
  }

  private func load() async {
    isLoading = true
    do {
      providers = try await client.listOpenCodeAuthProviders(accountId: account.id)
      if !isShared, account.profileKind == "default" {
        providers = providers.map { provider in
          var local = provider
          local.methods = provider.methods.filter { $0.type == "oauth" }
          return local
        }.filter { !$0.methods.isEmpty || $0.credentialType == "oauth" }
      }
      errorMessage = nil
    } catch {
      errorMessage = serverErrorMessage(error)
    }
    isLoading = false
    if !didOpenRequestedProvider, (startsSignIn || initialProviderId != nil), errorMessage == nil {
      didOpenRequestedProvider = true
      setupProvider = OpenCodeProviderSetupRequest(providerId: initialProviderId)
    }
  }

  private func activate() async {
    await perform("Switching profile…") {
      let accounts = try await client.activateHarnessAccount(
        harnessId: "opencode",
        accountId: account.id
      )
      if let updated = accounts.first(where: { $0.id == account.id }) { account = updated }
      onChange()
    }
  }

  private func remove(_ provider: ServerOpenCodeAuthProvider) async {
    await perform("Removing credential…") {
      try await client.removeOpenCodeAuthProvider(
        accountId: account.id,
        providerId: provider.id
      )
      await load()
      onChange()
    }
  }

  /// `label` is what the screen shows while this runs. Every blocking
  /// operation names itself; none of them runs silently.
  private func perform(_ label: String, _ operation: () async throws -> Void) async {
    workingLabel = label
    errorMessage = nil
    defer { workingLabel = nil }
    do {
      try await operation()
    } catch {
      errorMessage = serverErrorMessage(error)
    }
  }

  private func credentialDescription(_ type: String?) -> String {
    switch type {
    case "oauth": "Provider account"
    case "wellknown": "External credential"
    default: "API key"
    }
  }
}
