import CodevisorCore
import CodevisorUI
import SwiftUI

/// OpenCode credentials belong to providers inside a profile. iOS represents
/// that hierarchy with profile navigation and a focused provider setup sheet.
struct OpenCodeProviderAuthenticationScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
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
  @State private var workingLabel: String?
  private var isWorking: Bool { workingLabel != nil }
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
            .foregroundStyle(theme.statusError)
        }
      }

      Section("Profiles") {
        if isLoading, accounts.isEmpty {
          HStack {
            Spacer(); SheetLoadingView("Loading profiles…"); Spacer()
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
    .sheetStatus(workingLabel)
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
        .foregroundStyle(theme.textSecondary)
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
    await perform("Adding profile…") {
      _ = try await client.createHarnessAccount(harnessId: "opencode", label: name)
      await loadAccounts()
    }
  }

  private func activate(_ account: ServerHarnessAccount) async {
    await perform("Switching profile…") {
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
    await perform("Renaming profile…") {
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
    await perform("Removing profile…") {
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

  private func profileName(_ account: ServerHarnessAccount) -> String {
    account.profileKind == "default" ? "Default Profile" : account.label
  }
}
