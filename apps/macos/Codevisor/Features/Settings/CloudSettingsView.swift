import SwiftUI
import AppKit
import CodevisorCore
import CodevisorUI
import os

/// The "Cloud" section hosted in Settings → Machines — sign in to Codevisor
/// Cloud, see every machine connected to the account, rename or disconnect
/// them, and (under Advanced) point the app at a self-hosted cloud instance.
struct CloudSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var showsAdvanced = false
    @State private var serverURLText = ""
    @State private var serverError: String?
    @State private var isConnectingServer = false

    private var cloud: CloudAccountController { environment.cloud }

    /// Polls run ONLY while this section can actually be seen (see the
    /// matching pattern in MachinesSettingsView): the Machines section —
    /// which hosts it — is selected with no machine page pushed over it, and
    /// the Settings window is key/active.
    private var isPollingActive: Bool {
        controlActiveState != .inactive
            && SettingsRouter.shared.selectedTab == .machines
    }

    var body: some View {
        Section {
            switch cloud.state {
            case .signedOut:
                signedOutContent
            case .validating:
                validatingContent
            case let .signedIn(userEmail):
                signedInContent(userEmail: userEmail)
            }
            advancedDisclosure
        } header: {
            Text("Cloud")
        }
        // Refresh on appear and every 10s while visible, so presence dots
        // track machines connecting/disconnecting elsewhere.
        .task(id: isPollingActive) {
            guard isPollingActive else { return }
            while !Task.isCancelled {
                await cloud.refreshMachines()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Signed out

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("See and connect to all your machines from anywhere — end-to-end encrypted.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if cloud.supportsGitHubSignIn {
                    CloudSignInProviderButton(
                        title: "Sign in with GitHub",
                        icon: .asset("GitHubMark")
                    ) { startSignIn() }
                    .settingsActionTint(theme)
                }
            }
            if let lastError = cloud.lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(theme.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var validatingContent: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Signing in…")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private func signedInContent(userEmail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(userEmail ?? "Signed in")
                    .fontWeight(.medium)
                Text(cloud.serverURL.host() ?? cloud.serverURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign Out") { cloud.signOut() }
                .settingsActionTint(theme)
        }

        // Cloud machines are NOT listed here — they merge into the Machines
        // section above (see MachineController.allMachines) so each machine
        // appears exactly once.
        if let lastError = cloud.lastError {
            Text(lastError)
                .font(.callout)
                .foregroundStyle(theme.statusWarn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedDisclosure: some View {
        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                Text(currentServerDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField(
                        "Server URL",
                        text: $serverURLText,
                        // verbatim: keeps the prompt from being styled as
                        // a tappable link (same pattern as the MCP URL
                        // field).
                        prompt: Text(verbatim: "https://cloud.example.com")
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(isConnectingServer ? "Connecting…" : "Connect") {
                        connectCustomServer()
                    }
                    .settingsActionTint(theme)
                    .disabled(isConnectingServer)
                }
                if cloud.customServerURL != nil {
                    Button("Use Default Server") {
                        Task {
                            try? await cloud.setCustomServer(nil)
                            serverURLText = ""
                            serverError = nil
                        }
                    }
                    .settingsActionTint(theme)
                }
                if let serverError {
                    Text(serverError)
                        .font(.callout)
                        .foregroundStyle(theme.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        }
        .onAppear {
            serverURLText = cloud.customServerURL?.absoluteString ?? ""
        }
    }

    private var currentServerDescription: String {
        if let custom = cloud.customServerURL {
            if let instance = cloud.customInstanceName, !instance.isEmpty {
                return
                    "Using self-hosted server “\(instance)” at \(custom.absoluteString). Connecting to a different server signs you out."
            }
            return "Using self-hosted server \(custom.absoluteString). Connecting to a different server signs you out."
        }
        return
            "Using the default Codevisor Cloud. Enter the URL of a self-hosted instance to use it instead — connecting signs you out of the current server."
    }

    private func connectCustomServer() {
        let trimmed = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        serverError = nil
        guard !trimmed.isEmpty else {
            // An emptied field means "back to the default instance".
            Task {
                try? await cloud.setCustomServer(nil)
            }
            return
        }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.host() != nil else {
            serverError = "“\(trimmed)” isn't a valid URL."
            return
        }
        isConnectingServer = true
        Task {
            defer { isConnectingServer = false }
            do {
                try await cloud.setCustomServer(url)
                serverURLText = url.absoluteString
            } catch {
                Log.cloud.error("Custom cloud server validation failed: \(String(describing: error), privacy: .public)")
                serverError = ErrorReporter.userFacingMessage(for: error)
            }
        }
    }

    // MARK: - Sign-in flow

    /// The URL scheme this build registered (codevisor-dev for development
    /// builds), read from Info.plist so it always matches what the browser
    /// can actually call back to.
    private var callbackScheme: String {
        let registered = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }
            .first { $0.hasPrefix("codevisor") }
        return registered ?? (CodevisorAppVariant.isDevelopment ? "codevisor-dev" : "codevisor")
    }

    /// Opens the sign-in URL in the user's default browser (the same pattern
    /// terminal tools use). GitHub redirects to the handoff page, which
    /// bounces back into the app via the codevisor(-dev)://cloud-auth
    /// deeplink handled in ContentView — no embedded browser window.
    private func startSignIn() {
        cloud.lastError = nil
        NSWorkspace.shared.open(cloud.signInURL(scheme: callbackScheme))
    }

    // MARK: - Formatting

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    static func parseISODate(_ raw: String) -> Date? {
        isoFractionalFormatter.date(from: raw) ?? isoFormatter.date(from: raw)
    }
}

/// Sheet for renaming a machine connected to the cloud account.
struct RenameCloudMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name: String
    let machine: CloudMachine
    let onRename: (String) -> Void

    init(machine: CloudMachine, onRename: @escaping (String) -> Void) {
        self.machine = machine
        self.onRename = onRename
        _name = State(initialValue: machine.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename machine")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text(machine.deviceId)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .settingsActionTint(theme)
                Button("Save") {
                    onRename(name)
                    dismiss()
                }
                .settingsActionTint(theme)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

#Preview("Account") {
    CloudSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 520, height: 420)
}
