import CodevisorCore
import SwiftUI

/// OpenCode credentials belong to providers inside a profile. iOS represents
/// that hierarchy with profile navigation and a focused provider setup sheet.
struct OpenCodeProviderAuthenticationScreen: View {
    @Environment(AppEnvironment.self) private var environment

    let serverId: String
    let harness: ServerHarness
    var onAuthenticated: () -> Void = {}

    @State private var accounts: [ServerHarnessAccount] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingNewProfile = false
    @State private var newProfileName = ""
    @State private var pendingRename: ServerHarnessAccount?
    @State private var renameDraft = ""
    @State private var pendingRemoval: ServerHarnessAccount?

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: serverId)
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
                                onChange: { Task { await catalogChanged() } }
                            )
                        } label: {
                            profileRow(account)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if !account.isActive {
                                Button("Use") { Task { await activate(account) } }
                                    .tint(.blue)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if account.profileKind == "managed" {
                                Button("Remove", role: .destructive) {
                                    pendingRemoval = account
                                }
                                Button("Rename") { requestRename(account) }
                                    .tint(.blue)
                            }
                        }
                    }
                }

                Button {
                    newProfileName = "Profile \(accounts.filter { $0.profileKind == "managed" }.count + 1)"
                    showingNewProfile = true
                } label: {
                    Label("Add Profile", systemImage: "plus")
                }
                .disabled(isWorking)
            }
        }
        .task { await loadAccounts() }
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
        .confirmationDialog(
            "Remove Profile?",
            isPresented: removalIsPresented,
            titleVisibility: .visible
        ) {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(profileName(account))
                Text(account.profileKind == "default" ? "Local OpenCode" : "Managed profile")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
        account.profileKind == "default" ? "Local OpenCode" : account.label
    }
}

private struct OpenCodeProfileScreen: View {
    @Environment(AppEnvironment.self) private var environment

    let serverId: String
    let harness: ServerHarness
    @State private var account: ServerHarnessAccount
    let onChange: () -> Void

    @State private var providers: [ServerOpenCodeAuthProvider] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var setupProvider: OpenCodeProviderSetupRequest?

    init(
        serverId: String,
        harness: ServerHarness,
        initialAccount: ServerHarnessAccount,
        onChange: @escaping () -> Void
    ) {
        self.serverId = serverId
        self.harness = harness
        _account = State(initialValue: initialAccount)
        self.onChange = onChange
    }

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: serverId)
    }

    private var configuredProviders: [ServerOpenCodeAuthProvider] {
        providers.filter { $0.credentialType != nil }
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if account.isActive {
                    Label("Used for New Chats", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Use for New Chats") { Task { await activate() } }
                        .disabled(isWorking)
                }
            }

            Section("Providers") {
                if isLoading, providers.isEmpty {
                    HStack {
                        Spacer(); ProgressView(); Spacer()
                    }
                } else if configuredProviders.isEmpty {
                    Text("No providers configured.")
                        .foregroundStyle(.secondary)
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
                        Button("Remove", role: .destructive) { Task { await remove(provider) } }
                    }
                }

                Button {
                    setupProvider = OpenCodeProviderSetupRequest(providerId: nil)
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
                .disabled(isLoading || providers.isEmpty || isWorking)
            }
        }
        .navigationTitle(profileName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $setupProvider) { request in
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
        }
    }

    private var profileName: String {
        account.profileKind == "default" ? "Local OpenCode" : account.label
    }

    private func load() async {
        isLoading = true
        do {
            providers = try await client.listOpenCodeAuthProviders(accountId: account.id)
            errorMessage = nil
        } catch {
            errorMessage = serverErrorMessage(error)
        }
        isLoading = false
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
