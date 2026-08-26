import CodevisorCore
import SwiftUI
import UIKit

/// The iOS harness authentication flow, pinned to one machine: lists the
/// harness's accounts and walks whichever sign-in method the user picks —
/// browser, device-code, API-key, or an attached terminal (Claude's own
/// login flow runs in a PTY on the target machine and renders here).
/// Mirrors the macOS HarnessAuthenticationView's standard flow.
struct HarnessAuthenticationScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    let serverId: String
    @State var harness: ServerHarness
    var onAuthenticated: () -> Void = {}

    @State private var accounts: [ServerHarnessAccount] = []
    @State private var methods: [ServerHarnessAuthMethod] = []
    @State private var flow: ServerHarnessAuthFlow?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var apiKeyAccount: ServerHarnessAccount?
    @State private var apiKeyMethod: ServerHarnessAuthMethod?
    @State private var apiKey = ""

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: serverId)
    }

    var body: some View {
        Group {
            if let flow, flow.kind == "terminal", let terminalKey = flow.terminalAttachKey {
                terminalFlow(terminalKey: terminalKey)
            } else {
                accountsForm
            }
        }
        .task { await load() }
        .onDisappear {
            guard let flow else { return }
            Task {
                try? await client.cancelHarnessLogin(
                    harnessId: harness.id,
                    accountId: flow.accountId,
                    flowId: flow.id
                )
            }
        }
    }

    // MARK: - Layout

    private func terminalFlow(terminalKey: String) -> some View {
        VStack(spacing: 0) {
            TerminalPaneView(
                terminalKey: terminalKey,
                cwd: "/",
                config: environment.machines.serverConfig(for: serverId),
                attachOnly: true
            )
            Divider()
            authProgress
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var accountsForm: some View {
        Form {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section(accountSectionTitle) {
                ForEach(accounts) { account in accountRow(account) }
                if harness.auth?.supportsMultipleAccounts == true {
                    Button {
                        Task { await addAccount() }
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .disabled(isWorking)
                }
            }

            if let flow, flow.kind == "deviceCode" {
                Section("Sign In") {
                    Text("Enter this code in your browser:")
                    Text(flow.userCode ?? "")
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                    Button("Copy Code") { UIPasteboard.general.string = flow.userCode ?? "" }
                    if let value = flow.verificationUrl, let url = URL(string: value) {
                        Button("Open Browser") { openURL(url) }
                    }
                    authProgress
                }
            } else if flow != nil {
                Section("Sign In") { authProgress }
            }

            if let account = apiKeyAccount, let method = apiKeyMethod {
                Section(method.name) {
                    SecureField("API Key", text: $apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { submitApiKey(account: account, method: method) }
                    Text("The key is stored only on the selected Codevisor server for this account profile.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Sign In") { submitApiKey(account: account, method: method) }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                    Button("Cancel", role: .cancel) { clearApiKeyEntry() }
                }
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: ServerHarnessAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(account.isActive ? Color.primary : Color.secondary)
                .accessibilityLabel(account.isActive ? "Selected" : "Not selected")
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                Text(accountStatus(account))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if account.authState == "authenticated" || account.authState == "notRequired" {
                if !account.isActive {
                    Button("Use") { Task { await activate(account) } }
                        .buttonStyle(.borderless)
                }
            } else if account.canLogin {
                loginControl(account)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if account.canLogout,
                account.authState == "authenticated" || account.authState == "notRequired"
            {
                Button("Sign Out") { Task { await logout(account) } }
            }
            if account.profileKind == "managed" {
                Button("Remove", role: .destructive) { Task { await remove(account) } }
            }
        }
    }

    @ViewBuilder
    private func loginControl(_ account: ServerHarnessAccount) -> some View {
        if methods.count > 1 {
            Menu("Sign In") {
                ForEach(methods) { method in
                    Button(method.name) { selectLoginMethod(method, for: account) }
                }
            }
        } else {
            Button(methods.first?.name ?? "Sign In") {
                if let method = methods.first {
                    selectLoginMethod(method, for: account)
                } else {
                    Task { await login(account, methodId: nil) }
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var authProgress: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for sign-in…")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { Task { await cancelFlow() } }
        }
    }

    private var accountSectionTitle: String {
        harness.auth?.supportsMultipleAccounts == true ? "Accounts" : "Configuration"
    }

    private func accountStatus(_ account: ServerHarnessAccount) -> String {
        switch account.authState {
        case "authenticated": return account.email.map { "Signed in as \($0)" } ?? "Signed in"
        case "notRequired": return "No sign-in required"
        case "checking": return "Checking sign-in…"
        case "expired": return "Sign-in expired"
        // Plain language, never the probe's `detail` — that carries a crashed
        // CLI's stderr. The cause is summarized and persisted server-side.
        case "error": return "Something went wrong starting the CLI"
        default: return "Not signed in"
        }
    }

    // MARK: - Actions

    private func load() async {
        methods = harness.auth?.loginMethods ?? []
        do {
            accounts = try await client.listHarnessAccounts(harnessId: harness.id)
            errorMessage = nil
        } catch { errorMessage = serverErrorMessage(error) }
    }

    private func addAccount() async {
        await perform {
            _ = try await client.createHarnessAccount(harnessId: harness.id, label: nil)
            await load()
        }
    }

    private func activate(_ account: ServerHarnessAccount) async {
        await perform {
            accounts = try await client.activateHarnessAccount(harnessId: harness.id, accountId: account.id)
        }
        await refreshHarness()
    }

    private func logout(_ account: ServerHarnessAccount) async {
        await perform {
            _ = try await client.logoutHarnessAccount(harnessId: harness.id, accountId: account.id)
            await load()
        }
        await refreshHarness()
    }

    private func remove(_ account: ServerHarnessAccount) async {
        await perform {
            try await client.removeHarnessAccount(harnessId: harness.id, accountId: account.id)
            await load()
        }
        await refreshHarness()
    }

    private func selectLoginMethod(_ method: ServerHarnessAuthMethod, for account: ServerHarnessAccount) {
        if method.kind == "apiKey" {
            apiKey = ""
            apiKeyAccount = account
            apiKeyMethod = method
        } else {
            Task { await login(account, methodId: method.id) }
        }
    }

    private func submitApiKey(account: ServerHarnessAccount, method: ServerHarnessAuthMethod) {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task { await login(account, methodId: method.id, apiKey: value) }
    }

    private func clearApiKeyEntry() {
        apiKey = ""
        apiKeyAccount = nil
        apiKeyMethod = nil
    }

    private func login(_ account: ServerHarnessAccount, methodId: String?, apiKey: String? = nil) async {
        await perform {
            let next = try await client.loginHarnessAccount(
                harnessId: harness.id,
                accountId: account.id,
                methodId: methodId,
                apiKey: apiKey
            )
            clearApiKeyEntry()
            flow = next.kind == "complete" ? nil : next
            if let value = next.url, let url = URL(string: value) { openURL(url) }
            if let value = next.verificationUrl, let url = URL(string: value) { openURL(url) }
            if next.kind == "complete" {
                await finishAuthentication(accountId: account.id)
                return
            }
            Task { await poll(accountId: account.id) }
        }
    }

    private func poll(accountId: String) async {
        for _ in 0..<300 where !Task.isCancelled && flow != nil {
            try? await Task.sleep(for: .seconds(2))
            guard let account = try? await client.probeHarnessAccount(harnessId: harness.id, accountId: accountId)
            else { continue }
            if account.authState == "authenticated" || account.authState == "notRequired" {
                flow = nil
                await finishAuthentication(accountId: accountId)
                return
            }
            if account.authState == "error" {
                // Friendly text only — `detail` carries the probe's technical
                // cause (up to a crashed CLI's stderr) and never reaches the UI.
                let message = "Couldn't verify sign-in."
                await cancelFlow()
                await load()
                errorMessage = message
                return
            }
        }
    }

    private func finishAuthentication(accountId: String) async {
        if let activated = try? await client.activateHarnessAccount(
            harnessId: harness.id,
            accountId: accountId
        ) {
            accounts = activated
        } else {
            await load()
        }
        await refreshHarness()
        if harness.auth?.state == "authenticated" || harness.auth?.state == "notRequired" {
            onAuthenticated()
        }
    }

    private func cancelFlow() async {
        guard let current = flow else { return }
        flow = nil
        try? await client.cancelHarnessLogin(
            harnessId: harness.id,
            accountId: current.accountId,
            flowId: current.id
        )
    }

    private func refreshHarness() async {
        if let updated = try? await environment.refreshHarnessAuthentication(
            harnessId: harness.id, onServer: serverId)
        {
            harness = updated
            methods = updated.auth?.loginMethods ?? methods
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
            errorMessage = nil
        } catch { errorMessage = serverErrorMessage(error) }
    }
}
