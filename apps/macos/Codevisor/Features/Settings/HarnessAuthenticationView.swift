import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

struct HarnessAuthenticationView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.settingsMachineId) private var settingsMachineId

    /// The machine this view operates on — pinned by the machine-scoped
    /// Settings page that presented it, else the app's selected machine
    /// (onboarding, previews).
    private var scopedServerId: String {
        settingsMachineId ?? environment.machines.selectedMachineId
    }

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: scopedServerId)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let harness: ServerHarness
    var onChange: (ServerHarness) -> Void
    /// Settings/onboarding render this view standalone and want its own
    /// title + Done header. The composer's sign-in sheet brings its own
    /// chrome (with machine context) and turns this off.
    var showsHeader = true

    @State private var accounts: [ServerHarnessAccount] = []
    @State private var methods: [ServerHarnessAuthMethod] = []
    @State private var flow: ServerHarnessAuthFlow?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var apiKeyAccount: ServerHarnessAccount?
    @State private var apiKeyMethod: ServerHarnessAuthMethod?
    @State private var apiKey = ""
    @State private var authTerminalLifecycle = AuthTerminalLifecycle()
    /// The machine the login PTY lives on, with a DIALABLE baseURL: cloud
    /// machines resolve (and lazily start) their loopback bridge first.
    @State private var terminalMachine: CodevisorMachine?

    @ViewBuilder
    var body: some View {
        if harness.id == "pi" {
            PiProviderAuthenticationView(harness: harness, onChange: onChange, showsHeader: showsHeader)
        } else if harness.id == "opencode" {
            OpenCodeProviderAuthenticationView(
                harness: harness, onChange: onChange, showsHeader: showsHeader)
        } else {
            standardAuthentication
        }
    }

    private var standardAuthentication: some View {
        VStack(spacing: 0) {
            if showsHeader {
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
            }

            if let flow, flow.kind == "terminal", let terminalKey = flow.terminalAttachKey {
                VStack(alignment: .leading, spacing: 10) {
                    Text(terminalTitle).font(.headline)
                    if let terminalMachine {
                        AuthTerminalView(
                            terminalKey: terminalKey,
                            // The SCOPED machine, never the app selection:
                            // the login PTY lives on the machine this view
                            // was opened for, and a proxy pointed elsewhere
                            // retries HTTP 500s forever against a server
                            // that has no such terminal.
                            machine: terminalMachine,
                            lifecycle: authTerminalLifecycle
                        )
                        .frame(minHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 280)
                    }
                    authProgress
                }
                .padding(20)
                .task(id: flow.id) { await resolveTerminalMachine() }
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
                                    .disabled(
                                        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        // Standalone (settings/onboarding) sizes itself; hosted in the
        // composer sheet the SHEET owns the frame — a fixed inner width
        // wider than the sheet clips the content's own padding off-screen.
        .frame(
            minWidth: showsHeader ? 520 : nil,
            idealWidth: showsHeader ? 520 : nil,
            maxWidth: showsHeader ? 520 : .infinity,
            minHeight: showsHeader ? 390 : nil
        )
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
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(accountStatus(account))
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
                .help("More account actions")
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
        // Plain language, never the probe's `detail` — that carries a crashed
        // CLI's stderr. The cause is summarized and persisted server-side.
        case "error": return "Something went wrong starting the CLI"
        default: return "Not signed in"
        }
    }

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
            _ = try await client.logoutHarnessAccount(harnessId: harness.id, accountId: account.id); await load()
        }
        await refreshHarness()
    }

    private func remove(_ account: ServerHarnessAccount) async {
        await perform {
            try await client.removeHarnessAccount(harnessId: harness.id, accountId: account.id); await load()
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
            if let value = next.url, let url = URL(string: value) { NSWorkspace.shared.open(url) }
            if let value = next.verificationUrl, let url = URL(string: value) { NSWorkspace.shared.open(url) }
            if next.kind == "complete" { await finishAuthentication(accountId: account.id); return }
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
    }

    private func cancelFlow() async {
        guard let current = flow else { return }
        // Detach the proxy and finish libghostty teardown before the server
        // kills Claude's PTY. Reversing this order lets the proxy's child-exit
        // callback race SwiftUI dismantling the same surface.
        authTerminalLifecycle.terminate()
        flow = nil
        try? await client.cancelHarnessLogin(
            harnessId: harness.id,
            accountId: current.accountId,
            flowId: current.id
        )
    }

    /// The proxy dials a real socket, so a cloud machine must answer with
    /// its loopback-bridge address (started lazily here) instead of the
    /// relay placeholder.
    private func resolveTerminalMachine() async {
        var machine =
            environment.machines.machine(for: scopedServerId)
            ?? environment.machines.selectedMachine
        if let url = await environment.machines.effectiveHTTPBaseURL(forMachineId: scopedServerId) {
            machine.baseURL = url
        }
        terminalMachine = machine
    }

    private func refreshHarness() async {
        if let updated = try? await environment.refreshHarnessAuthentication(
            harnessId: harness.id, onServer: scopedServerId)
        {
            methods = updated.auth?.loginMethods ?? methods
            onChange(updated)
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do { try await operation(); errorMessage = nil } catch { errorMessage = serverErrorMessage(error) }
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
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
