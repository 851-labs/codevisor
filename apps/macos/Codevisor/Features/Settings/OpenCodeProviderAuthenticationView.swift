import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

struct OpenCodeProviderAuthenticationView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.sharedHarnessAccounts) var isShared
  @Environment(\.harnessMachineSignIn) var machineSignIn
  @Environment(\.settingsMachineId) private var settingsMachineId

  /// The machine this view operates on — pinned by the machine-scoped
  /// Settings page that presented it, else the app's selected machine
  /// (onboarding, previews).
  var scopedServerId: String {
    settingsMachineId ?? environment.defaultComposerServerId
  }

  var client: HarnessAccountsStore {
    HarnessAccountsStore(environment: environment, machineId: scopedServerId, isShared: isShared)
  }

  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) var theme

  let harness: ServerHarness
  var onChange: (ServerHarness) -> Void
  /// Hidden when hosted inside the composer's sign-in sheet, which
  /// carries its own title bar.
  var showsHeader = true
  var signInRequest: HarnessMachineSignIn?
  @State var didOpenRequestedProvider = false

  @State var accounts: [ServerHarnessAccount] = []
  @State var providers: [ServerOpenCodeAuthProvider] = []
  @State var providerAccountId: String?
  @State var selectedAccountId: String?
  @State var selectedProviderId: String?
  @State var selectedMethodId = ""
  @State var providerSearch = ""
  @State var inputs: [String: String] = [:]
  @State var apiKey = ""
  @State var authorizationCode = ""
  @State var flow: ServerOpenCodeAuthFlow?
  @State var pollingFlowId: String?
  @State var openedURL: String?
  /// The running blocking operation's label, or nil. Doubles as the
  /// is-working flag so the two can never disagree.
  @State var workingLabel: String?
  @State var isLoadingProviders = false
  @State var errorMessage: String?
  @State var showingProviderSignIn = false
  @State var pendingMachineSignIn: HarnessMachineSignIn?
  @State private var showingNewProfile = false
  @State var newProfileName = ""
  @State var profilePendingRename: ServerHarnessAccount?
  @State var profileNameDraft = ""
  @State var showingRenameProfile = false
  @State var profilePendingRemoval: ServerHarnessAccount?
  @State var showingRemoveProfileAlert = false

  var isWorking: Bool { workingLabel != nil }
  var footerStatus: String? { workingLabel }

  var body: some View {
    Group {
      if showsHeader {
        NavigationStack {
          profiles.navigationTitle("OpenCode Accounts")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          SheetFooter(status: footerStatus) {
            Button("Done") { dismiss() }
              .settingsActionTint(theme)
              .keyboardShortcut(.defaultAction)
              .disabled(isWorking)
          }
        }
        .sheetSize(.browser)
        .themedSurface(.sheet)
      } else {
        profiles
      }
    }
    .task { await loadAccounts() }
    .onChange(of: environment.configSync.revisionsByNamespace[HarnessSharedCredentials.namespace]) { _, _ in
      if isShared {
        Task {
          await loadAccounts()
          if !showingProviderSignIn, let id = selectedAccountId { await loadProviders(accountId: id) }
        }
      }
    }
    .task(id: selectedAccountId) {
      guard let accountId = selectedAccountId else {
        providers = []
        providerAccountId = nil
        selectedProviderId = nil
        isLoadingProviders = false
        return
      }
      await loadProviders(accountId: accountId)
    }
    .sheet(isPresented: $showingProviderSignIn, onDismiss: providerSheetDismissed) {
      providerSignInSheet
    }
    .alert("New Profile", isPresented: $showingNewProfile) {
      TextField("Name", text: $newProfileName)
      Button("Cancel", role: .cancel) {}
      Button("Add") { Task { await addProfile() } }
        .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .alert("Rename Profile", isPresented: $showingRenameProfile, presenting: profilePendingRename) { account in
      TextField("Name", text: $profileNameDraft)
      Button("Cancel", role: .cancel) {}
      Button("Rename") { Task { await renameProfile(account) } }
        .disabled(profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .alert("Remove Profile?", isPresented: $showingRemoveProfileAlert, presenting: profilePendingRemoval) {
      account in
      Button("Cancel", role: .cancel) {}
      Button("Remove", role: .destructive) { Task { await removeProfile(account) } }
    } message: { account in
      Text("This removes \(profileName(account)) and its provider credentials.")
    }
    .alert("OpenCode", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "OpenCode authentication failed.")
    }
    .onDisappear { cancelPendingFlow() }
  }

  private var profiles: some View {
    HStack(spacing: 0) {
      profileSidebar
      Divider()
      profileDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var profileSidebar: some View {
    VStack(spacing: 0) {
      List(selection: $selectedAccountId) {
        Section("Profiles") {
          ForEach(accounts) { account in
            profileRow(account)
              .tag(account.id)
              .contextMenu {
                if !account.isActive {
                  Button("Use for New Chats") { Task { await activate(account) } }
                }
                if account.profileKind == "managed" {
                  Divider()
                  Button("Rename Profile…") { requestProfileRename(account) }
                  Button("Remove Profile", role: .destructive) {
                    requestProfileRemoval(account)
                  }
                }
              }
          }
        }
      }
      .listStyle(.sidebar)

      Divider()

      HStack(spacing: 10) {
        Button {
          newProfileName = "Profile \(accounts.filter { $0.profileKind == "managed" }.count + 1)"
          showingNewProfile = true
        } label: {
          Image(systemName: "plus")
        }
        .help("Add Profile")
        .accessibilityLabel("Add Profile")

        Button {
          if let account = selectedAccount { requestProfileRemoval(account) }
        } label: {
          Image(systemName: "minus")
        }
        .disabled(selectedAccount?.profileKind != "managed" || isWorking)
        .help("Remove Profile")
        .accessibilityLabel("Remove Profile")

        Spacer()
      }
      .buttonStyle(.borderless)
      .settingsActionTint(theme)
      .padding(10)
    }
    .frame(width: 220)
  }

  @ViewBuilder
  private var profileDetail: some View {
    if let account = selectedAccount {
      VStack(spacing: 0) {
        Group {
          if isProviderContentLoading {
            SheetLoadingView("Loading providers…")
          } else if configuredProviders.isEmpty && !hasInheritedProviders {
            HarnessSignInInvitation(harnessId: harness.id, harnessName: harness.name) {
              Button("Sign In", systemImage: "plus") { prepareProviderSignIn() }
                .disabled(providers.isEmpty || isWorking)
            }
          } else {
            List(selection: $selectedProviderId) {
              Section("Providers") {
                if !isShared, account.profileKind == "default" {
                  HarnessSharedAccountRows(source: .opencode, excludingProviderIds: Set(configuredProviders.map(\.id)))
                }
                ForEach(configuredProviders) { provider in
                  providerRow(provider)
                    .tag(provider.id)
                    .contextMenu {
                      Button("Replace Credential…") { prepareProviderSignIn(provider) }
                      Button("Remove Credential", role: .destructive) {
                        Task { await remove(provider) }
                      }
                    }
                }
                // A trailing row rather than a second +/− bar. The sidebar
                // already owns one at the same vertical position; a second
                // pair 400pt to its right, meaning something else, was the
                // sheet's worst ambiguity. Removal lives on the row's
                // context menu, which is now its only affordance.
                Button("Add Provider…", systemImage: "plus") { prepareProviderSignIn() }
                  .buttonStyle(.plain)
                  .settingsActionTint(theme)
                  .disabled(isProviderContentLoading || providers.isEmpty || isWorking)
              }
            }
            .listStyle(.inset)
          }
        }
      }
    } else {
      ContentUnavailableView("No Profile Selected", systemImage: "person.crop.circle")
    }
  }

  private func profileRow(_ account: ServerHarnessAccount) -> some View {
    HStack(spacing: 8) {
      Image(systemName: account.profileKind == "default" ? "desktopcomputer" : "person.crop.circle")
        .foregroundStyle(theme.textSecondary)
        .frame(width: 18)
      Text(profileName(account))
        .lineLimit(1)
      Spacer()
      if account.isActive {
        Image(systemName: "checkmark")
          .accessibilityLabel("Used for new chats")
      }
    }
  }

  private func providerRow(_ provider: ServerOpenCodeAuthProvider) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "key.fill")
        .foregroundStyle(theme.textSecondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(provider.name)
        Text(credentialDescription(provider.credentialType))
          .font(.callout)
          .foregroundStyle(theme.textSecondary)
      }
      Spacer()
    }
    .padding(.vertical, 3)
  }

  var selectedAccount: ServerHarnessAccount? {
    accounts.first { $0.id == selectedAccountId }
  }

  private var configuredProviders: [ServerOpenCodeAuthProvider] {
    providers.filter {
      $0.credentialType != nil
        && (isShared || selectedAccount?.profileKind != "default" || $0.credentialType == "oauth")
    }
  }

  private var hasInheritedProviders: Bool {
    !isShared && selectedAccount?.profileKind == "default"
      && ((try? HarnessSharedCredentials.opencode.credentials(
        from: HarnessSharedCredentials.opencode.content(in: environment.configSync)
      ).isEmpty) == false)
  }

  var selectedProvider: ServerOpenCodeAuthProvider? {
    guard providerAccountId == selectedAccountId else { return nil }
    return providers.first { $0.id == selectedProviderId }
  }

  private var isProviderContentLoading: Bool {
    guard let selectedAccountId else { return false }
    return isLoadingProviders || providerAccountId != selectedAccountId
  }

  private var selectedConfiguredProvider: ServerOpenCodeAuthProvider? {
    guard let provider = selectedProvider, provider.credentialType != nil else { return nil }
    return provider
  }

  var selectedMethod: ServerOpenCodeAuthMethod? {
    selectedProvider?.methods.first { $0.id == selectedMethodId }
  }

  var filteredProviders: [ServerOpenCodeAuthProvider] {
    let query = providerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return providers }
    return providers.filter { $0.name.localizedStandardContains(query) }
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  func visiblePrompts(_ method: ServerOpenCodeAuthMethod) -> [ServerOpenCodeAuthPrompt] {
    method.prompts.filter { prompt in
      guard let condition = prompt.when else { return true }
      guard let actual = inputs[condition.key] else { return false }
      return condition.op == "eq" ? actual == condition.value : actual != condition.value
    }
  }

  func inputBinding(_ key: String) -> Binding<String> {
    Binding(
      get: { inputs[key] ?? "" },
      set: { inputs[key] = $0 }
    )
  }

  func canSubmit(_ method: ServerOpenCodeAuthMethod) -> Bool {
    if method.type == "api" && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return false
    }
    return visiblePrompts(method).allSatisfy { prompt in
      !(inputs[prompt.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  func selectDefaultMethod() {
    selectedMethodId = selectedProvider?.methods.first?.id ?? ""
    resetInput()
  }

  func resetInput() {
    inputs = [:]
    apiKey = ""
    if let method = selectedMethod {
      for prompt in method.prompts where prompt.type == "select" {
        inputs[prompt.key] = prompt.options.first?.value ?? ""
      }
    }
  }
}
