import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - Account

/// Codevisor Cloud account: sign in via the browser handoff, see every
/// machine connected to the account, rename or disconnect them, and (under
/// Advanced) point the app at a self-hosted instance — the iOS mirror of the
/// macOS Settings → Account pane.
struct CloudAccountScreen: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var signIn = CloudSignInCoordinator()
    @State private var isSigningIn = false
    @State private var serverURLText = ""
    @State private var serverError: String?
    @State private var isConnectingServer = false
    @State private var renaming: CloudMachine?
    @State private var renameText = ""
    @State private var removing: CloudMachine?
    @State private var trustingKey: CloudMachine?

    private var cloud: CloudAccountController { environment.cloud }

    var body: some View {
        List {
            switch cloud.state {
            case .signedOut:
                signedOutSection
            case .validating:
                validatingSection
            case let .signedIn(userEmail):
                signedInSections(userEmail: userEmail)
            }
            advancedSection
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        // Refresh on appear and every 10s while this screen is on screen (the
        // task cancels when it disappears — same pattern as tailnet discovery
        // in MachinesSettingsScreen), so presence dots track machines
        // connecting/disconnecting elsewhere.
        .task {
            while !Task.isCancelled {
                await cloud.refreshMachines()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onAppear {
            serverURLText = cloud.customServerURL?.absoluteString ?? ""
        }
        .alert(
            "Rename Machine",
            isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            ),
            presenting: renaming
        ) { machine in
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText
                Task { await cloud.rename(deviceId: machine.deviceId, name: name) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Disconnect “\(removing?.name ?? "")”?",
            isPresented: Binding(
                get: { removing != nil },
                set: { if !$0 { removing = nil } }
            ),
            titleVisibility: .visible,
            presenting: removing
        ) { machine in
            Button("Disconnect Machine", role: .destructive) {
                Task { await cloud.remove(deviceId: machine.deviceId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { machine in
            Text(
                "“\(machine.name)” will be signed out of your account. Nothing on the machine itself is changed — run codevisor auth login there to reconnect it."
            )
        }
        .confirmationDialog(
            "Trust the new key for “\(trustingKey?.name ?? "")”?",
            isPresented: Binding(
                get: { trustingKey != nil },
                set: { if !$0 { trustingKey = nil } }
            ),
            titleVisibility: .visible,
            presenting: trustingKey
        ) { machine in
            Button("Trust New Key", role: .destructive) {
                cloud.trustChangedMachineKey(deviceId: machine.deviceId)
            }
            Button("Cancel", role: .cancel) {}
        } message: { machine in
            Text(
                "“\(machine.name)” is presenting a different encryption key than the one this device remembers. That happens if the machine was re-provisioned — but it can also mean something between you and the machine is intercepting traffic. Only trust the new key if you expected this change."
            )
        }
    }

    // MARK: Signed out

    private var signedOutSection: some View {
        Section {
            if cloud.supportsGitHubSignIn {
                Button {
                    startSignIn()
                } label: {
                    HStack {
                        Text("Sign in with GitHub")
                        if isSigningIn {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isSigningIn)
            }
            if cloud.developmentAccountAvailable {
                Button("Use Development Account") {
                    Task { await cloud.signInWithDevelopmentAccount() }
                }
                .disabled(isSigningIn)
            }
            if let lastError = cloud.lastError {
                Text(lastError)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Codevisor Cloud")
        } footer: {
            Text("See and connect to all of your machines from anywhere — end-to-end encrypted.")
        }
    }

    private var validatingSection: some View {
        Section {
            HStack(spacing: 8) {
                ProgressView()
                Text("Signing in…")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Codevisor Cloud")
        }
    }

    // MARK: Signed in

    @ViewBuilder
    private func signedInSections(userEmail: String?) -> some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(userEmail ?? "Signed in")
                        .fontWeight(.medium)
                    Text(cloud.serverURL.host() ?? cloud.serverURL.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Sign Out", role: .destructive) {
                cloud.signOut()
            }
        } header: {
            Text("Account")
        }

        Section {
            if cloud.machines.isEmpty {
                InlineCodeText(
                    "No machines connected yet. Run `codevisor auth login` on a machine to connect it to your account."
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(cloud.machines) { machine in
                    machineRow(machine)
                }
            }
            if let lastError = cloud.lastError {
                Text(lastError)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Machines")
        }
    }

    private func machineRow(_ machine: CloudMachine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: machine.os == "linux" ? "server.rack" : "desktopcomputer")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .fontWeight(.medium)
                Text(machineSubtitle(machine))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if cloud.machinesWithChangedKeys.contains(machine.deviceId) {
                // TOFU refusal: the presented key conflicts with the pinned
                // one, so relay channels are cut off until re-trusted.
                Button {
                    trustingKey = machine
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .accessibilityHidden(true)
                        Text("Key Changed")
                            .font(.footnote)
                    }
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 5) {
                    Circle()
                        .fill(machine.online ? Color.green : Color.gray)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(
                        machine.online
                            ? (cloud.directPaths.machineIds.contains(machine.deviceId)
                                ? "Online · Direct" : "Online")
                            : "Offline"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                removing = machine
            } label: {
                Label("Disconnect", systemImage: "trash")
            }
            Button {
                renameText = machine.name
                renaming = machine
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
        .contextMenu {
            if cloud.machinesWithChangedKeys.contains(machine.deviceId) {
                Button {
                    trustingKey = machine
                } label: {
                    Label("Trust New Key…", systemImage: "exclamationmark.shield")
                }
            }
            Button {
                renameText = machine.name
                renaming = machine
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                removing = machine
            } label: {
                Label("Disconnect…", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func machineSubtitle(_ machine: CloudMachine) -> String {
        var parts: [String] = []
        if let os = machine.os, !os.isEmpty {
            parts.append(os == "macos" ? "macOS" : os.capitalized)
        }
        if !machine.online, let lastSeen = Self.parseISODate(machine.lastSeenAt) {
            parts.append("Last seen \(Self.relativeFormatter.localizedString(for: lastSeen, relativeTo: Date()))")
        }
        return parts.isEmpty ? machine.deviceId : parts.joined(separator: " · ")
    }

    // MARK: Advanced (self-hosted server)

    private var advancedSection: some View {
        Section {
            TextField("https://cloud.example.com", text: $serverURLText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button(isConnectingServer ? "Connecting…" : "Connect") {
                connectCustomServer()
            }
            .disabled(isConnectingServer)
            if cloud.customServerURL != nil {
                Button("Use Default Server") {
                    Task {
                        try? await cloud.setCustomServer(nil)
                        serverURLText = ""
                        serverError = nil
                    }
                }
            }
            if let serverError {
                Text(serverError)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text(currentServerDescription)
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

    // MARK: Sign-in flow

    private func startSignIn() {
        let scheme = CloudSignInCoordinator.callbackScheme
        isSigningIn = true
        cloud.lastError = nil
        signIn.start(
            url: cloud.signInURL(scheme: scheme),
            callbackScheme: scheme
        ) { callbackURL in
            isSigningIn = false
            guard let callbackURL,
                let deeplink = CloudAuthDeeplink.parse(callbackURL)
            else { return }
            Task { await cloud.completeSignIn(ott: deeplink.ott) }
        }
    }

    // MARK: Formatting

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

    private static func parseISODate(_ raw: String) -> Date? {
        isoFractionalFormatter.date(from: raw) ?? isoFormatter.date(from: raw)
    }
}
