import AppKit
import CodevisorCore
import SwiftUI

struct OpenCodeProviderAuthenticationView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let harness: ServerHarness
    var onChange: (ServerHarness) -> Void

    @State private var accounts: [ServerHarnessAccount] = []
    @State private var providers: [ServerOpenCodeAuthProvider] = []
    @State private var providerAccountId: String?
    @State private var selectedAccountId: String?
    @State private var selectedProviderId: String?
    @State private var selectedMethodId = ""
    @State private var providerSearch = ""
    @State private var inputs: [String: String] = [:]
    @State private var apiKey = ""
    @State private var authorizationCode = ""
    @State private var flow: ServerOpenCodeAuthFlow?
    @State private var pollingFlowId: String?
    @State private var openedURL: String?
    @State private var isWorking = false
    @State private var isLoadingProviders = false
    @State private var errorMessage: String?
    @State private var showingProviderSignIn = false
    @State private var showingNewProfile = false
    @State private var newProfileName = ""
    @State private var profilePendingRename: ServerHarnessAccount?
    @State private var profileNameDraft = ""
    @State private var showingRenameProfile = false
    @State private var profilePendingRemoval: ServerHarnessAccount?
    @State private var showingRemoveProfileAlert = false

    var body: some View {
        VStack(spacing: 0) {
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

            NavigationSplitView {
                profileSidebar
            } detail: {
                profileDetail
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 500, idealHeight: 540)
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
        .alert("Remove Profile?", isPresented: $showingRemoveProfileAlert, presenting: profilePendingRemoval) { account in
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

    private var providerSignInSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(flow == nil ? "Add Provider" : (selectedProvider?.name ?? "Sign In"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Cancel") { showingProviderSignIn = false }
                    .settingsActionTint(theme)
            }
            .padding(20)

            Divider()

            if let flow {
                Form {
                    Section(selectedProvider?.name ?? "Authentication") {
                        flowContent(flow)
                    }
                }
                .formStyle(.grouped)
            } else {
                VStack(spacing: 12) {
                    TextField("Search Providers", text: $providerSearch)
                        .textFieldStyle(.roundedBorder)

                    List(filteredProviders, selection: $selectedProviderId) { provider in
                        HStack {
                            Text(provider.name)
                            Spacer()
                            if provider.credentialType != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Configured")
                            }
                        }
                        .tag(provider.id)
                    }
                    .onChange(of: selectedProviderId) { _, _ in selectDefaultMethod() }
                    .frame(minHeight: 170)

                    Divider()

                    if let provider = selectedProvider {
                        authenticationControls(provider)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 480, idealWidth: 500, minHeight: 430, idealHeight: 480)
    }

    @ViewBuilder
    private func authenticationControls(_ provider: ServerOpenCodeAuthProvider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if provider.methods.count > 1 {
                Picker("Authentication", selection: $selectedMethodId) {
                    ForEach(provider.methods) { method in
                        Text(method.label).tag(method.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedMethodId) { _, _ in resetInput() }
            } else if let method = selectedMethod {
                LabeledContent("Authentication", value: method.label)
            }

            if let method = selectedMethod {
                ForEach(visiblePrompts(method)) { prompt in
                    promptControl(prompt)
                }
                if method.type == "api" {
                    SecureField("API Key", text: $apiKey)
                        .textContentType(.password)
                        .onSubmit { submitSelectedMethod() }
                }
                HStack {
                    Spacer()
                    Button(method.type == "api" ? "Save API Key" : "Sign In") {
                        Task { await beginLogin() }
                    }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit(method) || isWorking)
                }
            }
        }
    }

    @ViewBuilder
    private func promptControl(_ prompt: ServerOpenCodeAuthPrompt) -> some View {
        if prompt.type == "select" {
            Picker(prompt.message, selection: inputBinding(prompt.key)) {
                ForEach(prompt.options) { option in
                    Text(option.hint.map { "\(option.label) — \($0)" } ?? option.label)
                        .tag(option.value)
                }
            }
            .pickerStyle(.menu)
        } else {
            TextField(prompt.placeholder ?? prompt.message, text: inputBinding(prompt.key))
        }
    }

    @ViewBuilder
    private func flowContent(_ flow: ServerOpenCodeAuthFlow) -> some View {
        if let authorization = flow.authorization {
            if !authorization.instructions.isEmpty {
                Text(authorization.instructions)
                    .foregroundStyle(.secondary)
            }
            Button("Open Sign-In Page") { open(authorization.url) }
                .settingsActionTint(theme)
        }

        if flow.state == "waiting" {
            TextField("Authorization Code", text: $authorizationCode)
                .onSubmit { submitCode(flow) }
            HStack {
                Spacer()
                Button("Continue") { submitCode(flow) }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        } else if flow.state == "running" {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for sign-in…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedAccount: ServerHarnessAccount? {
        accounts.first { $0.id == selectedAccountId }
    }

    private var configuredProviders: [ServerOpenCodeAuthProvider] {
        providers.filter { $0.credentialType != nil }
    }

    private var selectedProvider: ServerOpenCodeAuthProvider? {
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

    private var selectedMethod: ServerOpenCodeAuthMethod? {
        selectedProvider?.methods.first { $0.id == selectedMethodId }
    }

    private var filteredProviders: [ServerOpenCodeAuthProvider] {
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

    private func visiblePrompts(_ method: ServerOpenCodeAuthMethod) -> [ServerOpenCodeAuthPrompt] {
        method.prompts.filter { prompt in
            guard let condition = prompt.when else { return true }
            guard let actual = inputs[condition.key] else { return false }
            return condition.op == "eq" ? actual == condition.value : actual != condition.value
        }
    }

    private func inputBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { inputs[key] ?? "" },
            set: { inputs[key] = $0 }
        )
    }

    private func canSubmit(_ method: ServerOpenCodeAuthMethod) -> Bool {
        if method.type == "api" && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return visiblePrompts(method).allSatisfy { prompt in
            !(inputs[prompt.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func selectDefaultMethod() {
        selectedMethodId = selectedProvider?.methods.first?.id ?? ""
        resetInput()
    }

    private func resetInput() {
        inputs = [:]
        apiKey = ""
        if let method = selectedMethod {
            for prompt in method.prompts where prompt.type == "select" {
                inputs[prompt.key] = prompt.options.first?.value ?? ""
            }
        }
    }

    private func loadAccounts() async {
        await perform {
            let loaded = try await environment.serverClient.listHarnessAccounts(harnessId: "opencode")
            accounts = loaded
            if !loaded.contains(where: { $0.id == selectedAccountId }) {
                selectedAccountId = loaded.first(where: \.isActive)?.id ?? loaded.first?.id
            }
        }
    }

    private func loadProviders(accountId: String) async {
        isLoadingProviders = true
        do {
            let loaded = try await environment.serverClient.listOpenCodeAuthProviders(accountId: accountId)
            guard selectedAccountId == accountId else { return }
            providers = loaded
            providerAccountId = accountId
            if !loaded.contains(where: { $0.id == selectedProviderId }) {
                selectedProviderId = loaded.first(where: { $0.credentialType != nil })?.id
            }
            selectDefaultMethod()
        } catch {
            guard selectedAccountId == accountId else { return }
            providers = []
            providerAccountId = accountId
            selectedProviderId = nil
            errorMessage = serverErrorMessage(error)
        }
        if selectedAccountId == accountId { isLoadingProviders = false }
    }

    private func addProfile() async {
        let label = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        await perform {
            let account = try await environment.serverClient.createHarnessAccount(harnessId: "opencode", label: label)
            accounts.append(account)
            selectedAccountId = account.id
        }
    }

    private func activate(_ account: ServerHarnessAccount) async {
        await perform {
            accounts = try await environment.serverClient.activateHarnessAccount(harnessId: "opencode", accountId: account.id)
        }
        await refreshHarness()
    }

    private func requestProfileRemoval(_ account: ServerHarnessAccount) {
        guard account.profileKind == "managed" else { return }
        profilePendingRemoval = account
        showingRemoveProfileAlert = true
    }

    private func requestProfileRename(_ account: ServerHarnessAccount) {
        guard account.profileKind == "managed" else { return }
        profilePendingRename = account
        profileNameDraft = profileName(account)
        showingRenameProfile = true
    }

    private func renameProfile(_ account: ServerHarnessAccount) async {
        let label = profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        await perform {
            let renamed = try await environment.serverClient.renameHarnessAccount(
                harnessId: "opencode",
                accountId: account.id,
                label: label
            )
            if let index = accounts.firstIndex(where: { $0.id == renamed.id }) {
                accounts[index] = renamed
            }
        }
        await refreshHarness()
    }

    private func removeProfile(_ account: ServerHarnessAccount) async {
        await perform {
            try await environment.serverClient.removeHarnessAccount(harnessId: "opencode", accountId: account.id)
            accounts = try await environment.serverClient.listHarnessAccounts(harnessId: "opencode")
            selectedAccountId = accounts.first(where: \.isActive)?.id ?? accounts.first?.id
        }
        await refreshHarness()
    }

    private func prepareProviderSignIn(_ provider: ServerOpenCodeAuthProvider? = nil) {
        let choice = provider ?? providers.first(where: { $0.credentialType == nil }) ?? providers.first
        selectedProviderId = choice?.id
        providerSearch = provider?.name ?? ""
        openedURL = nil
        selectDefaultMethod()
        showingProviderSignIn = choice != nil
    }

    private func submitSelectedMethod() {
        guard let method = selectedMethod, canSubmit(method) else { return }
        Task { await beginLogin() }
    }

    private func beginLogin() async {
        guard let account = selectedAccount, let provider = selectedProvider, let method = selectedMethod else { return }
        await perform {
            let next = try await environment.serverClient.startOpenCodeAuth(
                accountId: account.id,
                providerId: provider.id,
                methodId: method.id,
                inputs: inputs.isEmpty ? nil : inputs,
                apiKey: method.type == "api" ? apiKey : nil
            )
            await apply(next)
        }
    }

    private func submitCode(_ flow: ServerOpenCodeAuthFlow) {
        let code = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        Task {
            await perform {
                let next = try await environment.serverClient.answerOpenCodeAuthFlow(id: flow.id, code: code)
                authorizationCode = ""
                await apply(next)
            }
        }
    }

    private func apply(_ next: ServerOpenCodeAuthFlow) async {
        flow = next
        if let url = next.authorization?.url, openedURL != url {
            openedURL = url
            open(url)
        }
        if next.state == "complete" {
            flow = nil
            pollingFlowId = nil
            resetInput()
            if let accountId = selectedAccountId { await loadProviders(accountId: accountId) }
            await refreshHarness()
            showingProviderSignIn = false
        } else if next.state == "error" {
            errorMessage = next.error ?? "OpenCode authentication failed."
            flow = nil
            pollingFlowId = nil
        } else if next.state == "running" {
            beginPolling(next.id)
        }
    }

    private func beginPolling(_ id: String) {
        guard pollingFlowId != id else { return }
        pollingFlowId = id
        Task {
            while !Task.isCancelled, pollingFlowId == id {
                try? await Task.sleep(for: .seconds(1))
                guard let next = try? await environment.serverClient.openCodeAuthFlow(id: id) else { continue }
                let pending = next.state == "running" || next.state == "waiting"
                if !pending { pollingFlowId = nil }
                await apply(next)
                if !pending { return }
            }
        }
    }

    private func providerSheetDismissed() {
        cancelPendingFlow()
        providerSearch = ""
        authorizationCode = ""
    }

    private func cancelPendingFlow() {
        guard let flow, flow.state == "running" || flow.state == "waiting" else { return }
        self.flow = nil
        pollingFlowId = nil
        Task { try? await environment.serverClient.cancelOpenCodeAuthFlow(id: flow.id) }
    }

    private func remove(_ provider: ServerOpenCodeAuthProvider) async {
        guard let account = selectedAccount else { return }
        await perform {
            try await environment.serverClient.removeOpenCodeAuthProvider(accountId: account.id, providerId: provider.id)
            await loadProviders(accountId: account.id)
            await refreshHarness()
        }
    }

    private func refreshHarness() async {
        if let updated = try? await environment.refreshHarnessAuthentication(harnessId: "opencode") {
            accounts = updated.auth?.accounts ?? accounts
            onChange(updated)
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
        case "oauth": return "Provider Account"
        case "wellknown": return "External Credential"
        default: return "API Key"
        }
    }

    private func profileName(_ account: ServerHarnessAccount) -> String {
        if account.profileKind == "default" { return "Local OpenCode" }
        if account.label.hasPrefix("OpenCode profile "),
           let index = accounts.filter({ $0.profileKind == "managed" }).firstIndex(where: { $0.id == account.id }) {
            return "Profile \(index + 1)"
        }
        return account.label
    }

    private func open(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
