import AppKit
import CodevisorCore
import SwiftUI

struct HarnessAuthenticationView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let harness: ServerHarness
    var onChange: (ServerHarness) -> Void

    @State private var accounts: [ServerHarnessAccount] = []
    @State private var methods: [ServerHarnessAuthMethod] = []
    @State private var flow: ServerHarnessAuthFlow?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var apiKeyAccount: ServerHarnessAccount?
    @State private var apiKeyMethod: ServerHarnessAuthMethod?
    @State private var apiKey = ""
    @State private var authTerminalLifecycle = AuthTerminalLifecycle()

    @ViewBuilder
    var body: some View {
        if harness.id == "pi" {
            PiProviderAuthenticationView(harness: harness, onChange: onChange)
        } else {
            standardAuthentication
        }
    }

    private var standardAuthentication: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(authenticationTitle).font(.title2).fontWeight(.semibold)
                    Text(authenticationSubtitle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if let flow, flow.kind == "terminal", let terminalKey = flow.terminalAttachKey {
                VStack(alignment: .leading, spacing: 10) {
                    Text(terminalTitle).font(.headline)
                    AuthTerminalView(
                        terminalKey: terminalKey,
                        machine: environment.machines.selectedMachine,
                        lifecycle: authTerminalLifecycle
                    )
                        .frame(minHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    authProgress
                }
                .padding(20)
            } else {
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
                            .settingsActionTint(theme)
                            .disabled(isWorking)
                        }
                    }

                    if let flow, flow.kind == "deviceCode" {
                        Section("Sign In") {
                            Text("Enter this code in your browser:")
                            Text(flow.userCode ?? "")
                                .font(.system(.title2, design: .monospaced, weight: .semibold))
                                .textSelection(.enabled)
                            HStack {
                                Button("Copy Code") { copy(flow.userCode ?? "") }
                                    .settingsActionTint(theme)
                                if let value = flow.verificationUrl, let url = URL(string: value) {
                                    Button("Open Browser") { NSWorkspace.shared.open(url) }
                                        .settingsActionTint(theme)
                                }
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
                                .onSubmit { submitApiKey(account: account, method: method) }
                            Text("The key is stored only on the selected Codevisor server for this account profile.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Cancel") { clearApiKeyEntry() }
                                    .settingsActionTint(theme)
                                Spacer()
                                Button("Sign In") { submitApiKey(account: account, method: method) }
                                    .settingsActionTint(theme)
                                    .keyboardShortcut(.defaultAction)
                                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(minWidth: 520, idealWidth: 520, maxWidth: 520, minHeight: 390)
        .task { await load() }
        .onDisappear {
            guard let flow else { return }
            Task { try? await environment.serverClient.cancelHarnessLogin(
                harnessId: harness.id,
                accountId: flow.accountId,
                flowId: flow.id
            ) }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: ServerHarnessAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(account.isActive ? theme.textPrimary : theme.textSecondary)
                .accessibilityLabel(account.isActive ? "Selected" : "Not selected")
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label)
                Text(accountStatus(account))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if account.authState == "authenticated" || account.authState == "notRequired" {
                if !account.isActive {
                    Button("Use") { Task { await activate(account) } }
                        .settingsActionTint(theme)
                }
                if account.canLogout {
                    Button("Sign Out") { Task { await logout(account) } }
                        .settingsActionTint(theme)
                }
            } else if account.canLogin {
                loginControl(account)
            }
            if account.profileKind == "managed" {
                Menu {
                    Button("Remove Account", role: .destructive) { Task { await remove(account) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .settingsActionTint(theme)
                .accessibilityLabel("More account actions")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func loginControl(_ account: ServerHarnessAccount) -> some View {
        if methods.count > 1 {
            Menu("Sign In") {
                ForEach(methods) { method in
                    Button(method.name) { selectLoginMethod(method, for: account) }
                }
            }
            .settingsActionTint(theme)
        } else {
            Button(methods.first?.name ?? "Sign In") {
                if let method = methods.first {
                    selectLoginMethod(method, for: account)
                } else {
                    Task { await login(account, methodId: nil) }
                }
            }
            .settingsActionTint(theme)
        }
    }

    private var authProgress: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(harness.id == "pi" ? "Waiting for Pi configuration…" : "Waiting for sign-in…")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { Task { await cancelFlow() } }
                .settingsActionTint(theme)
        }
    }

    private var authenticationTitle: String {
        harness.auth?.supportsMultipleAccounts == true ? "\(harness.name) Accounts" : "\(harness.name) Setup"
    }

    private var authenticationSubtitle: String {
        if harness.id == "pi" {
            return "Configure the model providers Pi can use for new chats."
        }
        return harness.auth?.supportsMultipleAccounts == true
            ? "Choose the account Codevisor uses for new chats."
            : "Configure the credentials Codevisor uses for new chats."
    }

    private var terminalTitle: String {
        harness.id == "pi" ? "Configure Pi below" : "Finish signing in below"
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
        case "error": return account.detail ?? "Couldn't check sign-in"
        default: return "Not signed in"
        }
    }

    private func load() async {
        methods = harness.auth?.loginMethods ?? []
        do {
            accounts = try await environment.serverClient.listHarnessAccounts(harnessId: harness.id)
            errorMessage = nil
        } catch { errorMessage = serverErrorMessage(error) }
    }

    private func addAccount() async {
        await perform {
            _ = try await environment.serverClient.createHarnessAccount(harnessId: harness.id, label: nil)
            await load()
        }
    }

    private func activate(_ account: ServerHarnessAccount) async {
        await perform { accounts = try await environment.serverClient.activateHarnessAccount(harnessId: harness.id, accountId: account.id) }
        await refreshHarness()
    }

    private func logout(_ account: ServerHarnessAccount) async {
        await perform { _ = try await environment.serverClient.logoutHarnessAccount(harnessId: harness.id, accountId: account.id); await load() }
        await refreshHarness()
    }

    private func remove(_ account: ServerHarnessAccount) async {
        await perform { try await environment.serverClient.removeHarnessAccount(harnessId: harness.id, accountId: account.id); await load() }
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
            let next = try await environment.serverClient.loginHarnessAccount(
                harnessId: harness.id,
                accountId: account.id,
                methodId: methodId,
                apiKey: apiKey
            )
            clearApiKeyEntry()
            flow = next.kind == "complete" ? nil : next
            if let value = next.url, let url = URL(string: value) { NSWorkspace.shared.open(url) }
            if let value = next.verificationUrl, let url = URL(string: value) { NSWorkspace.shared.open(url) }
            if next.kind == "complete" { await finishAuthentication(accountId: account.id); return }
            Task { await poll(accountId: account.id) }
        }
    }

    private func poll(accountId: String) async {
        for _ in 0..<300 where !Task.isCancelled && flow != nil {
            try? await Task.sleep(for: .seconds(2))
            guard let account = try? await environment.serverClient.probeHarnessAccount(harnessId: harness.id, accountId: accountId) else { continue }
            if account.authState == "authenticated" || account.authState == "notRequired" {
                flow = nil
                await finishAuthentication(accountId: accountId)
                return
            }
        }
    }

    private func finishAuthentication(accountId: String) async {
        if let activated = try? await environment.serverClient.activateHarnessAccount(
            harnessId: harness.id,
            accountId: accountId
        ) {
            accounts = activated
        } else {
            await load()
        }
        await refreshHarness()
    }

    private func cancelFlow() async {
        guard let current = flow else { return }
        // Detach the proxy and finish libghostty teardown before the server
        // kills Claude's PTY. Reversing this order lets the proxy's child-exit
        // callback race SwiftUI dismantling the same surface.
        authTerminalLifecycle.terminate()
        flow = nil
        try? await environment.serverClient.cancelHarnessLogin(
            harnessId: harness.id,
            accountId: current.accountId,
            flowId: current.id
        )
    }

    private func refreshHarness() async {
        if let updated = try? await environment.refreshHarnessAuthentication(harnessId: harness.id) {
            methods = updated.auth?.loginMethods ?? methods
            onChange(updated)
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do { try await operation(); errorMessage = nil }
        catch { errorMessage = serverErrorMessage(error) }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct AuthTerminalView: NSViewRepresentable {
    let terminalKey: String
    let machine: CodevisorMachine
    let lifecycle: AuthTerminalLifecycle

    func makeNSView(context: Context) -> NSView {
        let descriptor = TerminalLaunchDescriptor(
            terminalKey: terminalKey,
            attachOnly: true,
            machine: machine,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            command: TerminalProxyCommand.command(
                server: machine.baseURL,
                terminalKey: terminalKey,
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                token: machine.token,
                attachOnly: true
            )
        )
        let surface = TerminalRuntime.factory.makeSurface(descriptor: descriptor)
        context.coordinator.surface = surface
        lifecycle.attach(surface)
        let container = NSView()
        let child = surface.nsView
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        guard let surface = coordinator.surface else { return }
        surface.terminate()
        coordinator.lifecycle?.detach(surface)
        coordinator.surface = nil
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(lifecycle: lifecycle) }

    final class Coordinator {
        weak var lifecycle: AuthTerminalLifecycle?
        var surface: (any TerminalSurface)?

        init(lifecycle: AuthTerminalLifecycle) {
            self.lifecycle = lifecycle
        }
    }
}

@MainActor
private final class AuthTerminalLifecycle {
    private var surface: (any TerminalSurface)?

    func attach(_ surface: any TerminalSurface) {
        self.surface = surface
    }

    func terminate() {
        surface?.terminate()
        surface = nil
    }

    func detach(_ candidate: any TerminalSurface) {
        if let surface, surface === candidate {
            self.surface = nil
        }
    }
}
