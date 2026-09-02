import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

struct OpenCodeProviderAuthenticationView: View {
    @Environment(AppEnvironment.self) var environment
    @Environment(\.settingsMachineId) private var settingsMachineId

    /// The machine this view operates on — pinned by the machine-scoped
    /// Settings page that presented it, else the app's selected machine
    /// (onboarding, previews).
    var scopedServerId: String {
        settingsMachineId ?? environment.defaultComposerServerId
    }

    var client: any CodevisorServerClienting {
        environment.machines.client(for: scopedServerId)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) var theme

    let harness: ServerHarness
    var onChange: (ServerHarness) -> Void
    /// Hidden when hosted inside the composer's sign-in sheet, which
    /// carries its own title bar.
    var showsHeader = true

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
    @State var isWorking = false
    @State var isLoadingProviders = false
    @State var errorMessage: String?
    @State var showingProviderSignIn = false
    @State private var showingNewProfile = false
    @State var newProfileName = ""
    @State var profilePendingRename: ServerHarnessAccount?
    @State var profileNameDraft = ""
    @State var showingRenameProfile = false
    @State var profilePendingRemoval: ServerHarnessAccount?
    @State var showingRemoveProfileAlert = false

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 12) {
                    HarnessIcon(harnessId: "opencode", fallbackSymbolName: harness.symbolName, size: 30)
                    Text("OpenCode Accounts")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Done") { dismiss() }
                        .settingsActionTint(theme)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(20)

                Divider()
            }

            NavigationSplitView {
                profileSidebar
            } detail: {
                profileDetail
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(
            minWidth: showsHeader ? 720 : nil,
            idealWidth: showsHeader ? 760 : nil,
            minHeight: showsHeader ? 500 : nil,
            idealHeight: showsHeader ? 540 : nil
        )
        .task { await loadAccounts() }
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
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
    }

    @ViewBuilder
    private var profileDetail: some View {
        if let account = selectedAccount {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profileName(account))
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text(account.profileKind == "default" ? "Local OpenCode" : "Managed Profile")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if account.isActive {
                        Label("New Chats", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Use for New Chats") { Task { await activate(account) } }
                            .settingsActionTint(theme)
                            .disabled(isWorking)
                    }
                }
                .padding(20)

                Divider()

                Group {
                    if isProviderContentLoading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Loading providers")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if configuredProviders.isEmpty {
                        ContentUnavailableView("No Providers", systemImage: "key")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $selectedProviderId) {
                            Section("Providers") {
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
                            }
                        }
                        .listStyle(.inset)
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        prepareProviderSignIn()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isProviderContentLoading || providers.isEmpty || isWorking)
                    .help("Add Provider")
                    .accessibilityLabel("Add Provider")

                    Button {
                        if let provider = selectedConfiguredProvider { Task { await remove(provider) } }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedConfiguredProvider == nil || isWorking)
                    .help("Remove Credential")
                    .accessibilityLabel("Remove Credential")

                    Spacer()
                }
                .buttonStyle(.borderless)
                .settingsActionTint(theme)
                .padding(10)
            }
        } else {
            ContentUnavailableView("No Profile Selected", systemImage: "person.crop.circle")
        }
    }

    private func profileRow(_ account: ServerHarnessAccount) -> some View {
        HStack(spacing: 8) {
            Image(systemName: account.profileKind == "default" ? "desktopcomputer" : "person.crop.circle")
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Text(credentialDescription(provider.credentialType))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    var selectedAccount: ServerHarnessAccount? {
        accounts.first { $0.id == selectedAccountId }
    }

    private var configuredProviders: [ServerOpenCodeAuthProvider] {
        providers.filter { $0.credentialType != nil }
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
