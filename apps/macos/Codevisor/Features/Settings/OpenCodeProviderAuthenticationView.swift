import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

struct OpenCodeProviderAuthenticationView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.sharedHarnessAccounts) var isShared
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
  /// The sign-in request applies to the profile first shown, once.
  @State var didOpenRequestedProvider = false

  @State var accounts: [ServerHarnessAccount] = []
  @State var selectedAccountId: String?
  /// The running profile operation's label, or nil. Doubles as the
  /// is-working flag so the two can never disagree.
  @State var workingLabel: String?
  /// What the providers pane is doing, for this sheet's own footer.
  @State private var providersWorkingLabel: String?
  @State var errorMessage: String?
  /// Profiles come in once per sheet; until then the sheet says it is
  /// loading (or why it couldn't) instead of looking empty.
  @State var profilesLoaded = false
  @State var profilesError: String?
  @State private var showingNewProfile = false
  @State var newProfileName = ""
  @State var profilePendingRename: ServerHarnessAccount?
  @State var profileNameDraft = ""
  @State var showingRenameProfile = false
  @State var profilePendingRemoval: ServerHarnessAccount?
  @State var showingRemoveProfileAlert = false

  var isWorking: Bool { workingLabel != nil }
  var footerStatus: String? { workingLabel ?? providersWorkingLabel }

  var body: some View {
    Group {
      if showsHeader {
        NavigationStack {
          profiles.navigationTitle("OpenCode Accounts")
        }
        .onPreferenceChange(HarnessAccountsWorkingPreference.self) { providersWorkingLabel = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          SheetFooter(status: footerStatus) {
            Button("Done") { dismiss() }
              .settingsActionTint(theme)
              .keyboardShortcut(.defaultAction)
              .disabled(footerStatus != nil)
          }
        }
        .sheetSize(.browser)
        .themedSurface(.sheet)
      } else {
        profiles
      }
    }
    // The hosting sheet shows the current operation in its own footer.
    .harnessWorking(workingLabel)
    .task { await loadAccounts() }
    .onChange(of: environment.configSync.revisionsByNamespace[HarnessSharedCredentials.namespace]) { _, _ in
      if isShared { Task { await loadAccounts() } }
    }
    .onChange(of: selectedAccountId) { previous, _ in
      if previous != nil { didOpenRequestedProvider = true }
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
        .disabled(!profilesLoaded || isWorking)
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
      HarnessProviderAccountsView(
        harness: harness, machineId: scopedServerId, profile: account,
        request: didOpenRequestedProvider ? nil : signInRequest
      ) { await refreshHarness() }
      .id(account.id)
    } else if let profilesError {
      ContentUnavailableView {
        Label("Couldn’t Load Profiles", systemImage: "exclamationmark.triangle")
      } description: {
        Text(profilesError)
      } actions: {
        Button("Retry") { Task { await loadAccounts() } }
      }
    } else if !profilesLoaded {
      SheetLoadingView("Loading profiles…")
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

  var selectedAccount: ServerHarnessAccount? {
    accounts.first { $0.id == selectedAccountId }
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }
}
