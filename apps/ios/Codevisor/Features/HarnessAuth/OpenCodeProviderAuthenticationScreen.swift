import CodevisorCore
import CodevisorUI
import SwiftUI

/// OpenCode credentials belong to providers inside a profile. iOS represents
/// that hierarchy with profile navigation and a focused provider setup sheet.
struct OpenCodeProviderAuthenticationScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.sharedHarnessAccounts) private var isShared
  @Environment(\.harnessMachineSignIn) private var machineSignIn

  let serverId: String
  let harness: ServerHarness
  var onAuthenticated: () -> Void = {}
  var signInRequest: HarnessMachineSignIn?
  @State private var requestedAccount: ServerHarnessAccount?
  @State private var showsRequestedAccount = false
  @State private var didOpenRequestedAccount = false

  @State private var accounts: [ServerHarnessAccount] = []
  @State private var isLoading = true
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var showingNewProfile = false
  @State private var newProfileName = ""
  @State private var pendingRename: ServerHarnessAccount?
  @State private var renameDraft = ""
  @State private var pendingRemoval: ServerHarnessAccount?

  private var client: HarnessAccountsStore {
    HarnessAccountsStore(environment: environment, machineId: serverId, isShared: isShared)
  }

  var body: some View {
    List {
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        }
      }

      Section("Profiles") {
        if isLoading, accounts.isEmpty {
          HStack {
            Spacer(); ProgressView(); Spacer()
          }
        } else {
          ForEach(accounts) { account in
            NavigationLink {
              OpenCodeProfileScreen(
                serverId: serverId,
                harness: harness,
                initialAccount: account,
                isShared: isShared,
                machineSignIn: machineSignIn,
                onChange: { Task { await catalogChanged() } }
              )
              .environment(\.sharedHarnessAccounts, isShared)
              .environment(\.harnessMachineSignIn, machineSignIn)
            } label: {
              profileRow(account)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
              if !account.isActive {
                Button("Use", systemImage: "checkmark") { Task { await activate(account) } }.labelStyle(.iconOnly)
                  .tint(.blue)
              }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              if account.profileKind == "managed" {
                Button("Remove", systemImage: "trash", role: .destructive) {
                  pendingRemoval = account
                }.labelStyle(.iconOnly)
                Button("Rename", systemImage: "pencil") { requestRename(account) }.labelStyle(.iconOnly)
                  .tint(.blue)
              }
            }
          }
        }

      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Add Profile", systemImage: "plus") {
          newProfileName = "Profile \(accounts.filter { $0.profileKind == "managed" }.count + 1)"
          showingNewProfile = true
        }.labelStyle(.iconOnly).disabled(isWorking)
      }
      HarnessAccountsCloseToolbar()
    }
    .task { await loadAccounts() }
    .onChange(of: environment.configSync.revisionsByNamespace[HarnessSharedCredentials.namespace]) { _, _ in
      if isShared { Task { await loadAccounts() } }
    }
    .navigationDestination(isPresented: $showsRequestedAccount) {
      if let account = requestedAccount {
        OpenCodeProfileScreen(
          serverId: serverId, harness: harness, initialAccount: account,
          isShared: isShared, machineSignIn: machineSignIn,
          initialProviderId: signInRequest?.providerId, startsSignIn: true,
          onChange: { Task { await catalogChanged() } }
        )
        .environment(\.sharedHarnessAccounts, isShared)
        .environment(\.harnessMachineSignIn, machineSignIn)
      }
    }
    .alert("New Profile", isPresented: $showingNewProfile) {
      TextField("Name", text: $newProfileName)
      Button("Cancel", role: .cancel) {}
      Button("Add") { Task { await addProfile() } }
        .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .alert("Rename Profile", isPresented: renameIsPresented) {
      TextField("Name", text: $renameDraft)
      Button("Cancel", role: .cancel) { pendingRename = nil }
      Button("Rename") { Task { await renameProfile() } }
    }
    .alert("Remove Profile?", isPresented: removalIsPresented) {
      Button("Remove Profile", role: .destructive) { Task { await removeProfile() } }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text("This also removes the profile’s provider credentials.")
    }
  }

  private func profileRow(_ account: ServerHarnessAccount) -> some View {
    HStack(spacing: 10) {
      Image(systemName: account.profileKind == "default" ? "desktopcomputer" : "person.crop.circle")
        .foregroundStyle(.secondary)
        .frame(width: 22)
      Text(profileName(account))
      Spacer()
      if account.isActive {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .accessibilityLabel("Used for new chats")
      }
    }
  }

  private var renameIsPresented: Binding<Bool> {
    Binding(
      get: { pendingRename != nil },
      set: { if !$0 { pendingRename = nil } }
    )
  }

  private var removalIsPresented: Binding<Bool> {
    Binding(
      get: { pendingRemoval != nil },
      set: { if !$0 { pendingRemoval = nil } }
    )
  }

  private func loadAccounts() async {
    isLoading = true
    do {
      accounts = try await client.listHarnessAccounts(harnessId: "opencode")
      if !didOpenRequestedAccount, let profileId = signInRequest?.profileId,
        let account = accounts.first(where: {
          profileId == "default" ? $0.profileKind == "default" : $0.id == profileId
        })
      {
        didOpenRequestedAccount = true
        requestedAccount = account
        showsRequestedAccount = true
      }
      errorMessage = nil
    } catch {
      errorMessage = serverErrorMessage(error)
    }
    isLoading = false
  }

  private func addProfile() async {
    let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    await perform {
      _ = try await client.createHarnessAccount(harnessId: "opencode", label: name)
      await loadAccounts()
    }
  }

  private func activate(_ account: ServerHarnessAccount) async {
    await perform {
      accounts = try await client.activateHarnessAccount(
        harnessId: "opencode",
        accountId: account.id
      )
      await catalogChanged()
    }
  }

  private func requestRename(_ account: ServerHarnessAccount) {
    pendingRename = account
    renameDraft = profileName(account)
  }

  private func renameProfile() async {
    guard let account = pendingRename else { return }
    let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    pendingRename = nil
    await perform {
      _ = try await client.renameHarnessAccount(
        harnessId: "opencode",
        accountId: account.id,
        label: name
      )
      await loadAccounts()
    }
  }

  private func removeProfile() async {
    guard let account = pendingRemoval else { return }
    pendingRemoval = nil
    await perform {
      try await client.removeHarnessAccount(harnessId: "opencode", accountId: account.id)
      await loadAccounts()
      await catalogChanged()
    }
  }

  private func catalogChanged() async {
    await loadAccounts()
    if isShared { return }
    guard
      let updated = try? await environment.refreshHarnessAuthentication(
        harnessId: "opencode",
        onServer: serverId
      )
    else { return }
    let wasUsable = harness.auth?.state == "authenticated" || harness.auth?.state == "notRequired"
    if !wasUsable,
      updated.auth?.state == "authenticated" || updated.auth?.state == "notRequired"
    {
      onAuthenticated()
    }
  }

  private func perform(_ operation: () async throws -> Void) async {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      try await operation()
    } catch {
      errorMessage = serverErrorMessage(error)
    }
  }

  private func profileName(_ account: ServerHarnessAccount) -> String {
    account.profileKind == "default" ? "Default Profile" : account.label
  }
}

private struct OpenCodeProfileScreen: View {
  @Environment(AppEnvironment.self) private var environment
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
  @State private var isWorking = false
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
        HarnessAccountsLoadingView()
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
            .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .frame(width: 22)
              VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).foregroundStyle(Color.primary)
                Text(credentialDescription(provider.credentialType))
                  .font(.footnote)
                  .foregroundStyle(.secondary)
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
    await perform {
      let accounts = try await client.activateHarnessAccount(
        harnessId: "opencode",
        accountId: account.id
      )
      if let updated = accounts.first(where: { $0.id == account.id }) { account = updated }
      onChange()
    }
  }

  private func remove(_ provider: ServerOpenCodeAuthProvider) async {
    await perform {
      try await client.removeOpenCodeAuthProvider(
        accountId: account.id,
        providerId: provider.id
      )
      await load()
      onChange()
    }
  }

  private func perform(_ operation: () async throws -> Void) async {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
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
