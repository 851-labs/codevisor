import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

/// App settings, mirroring the macOS settings window's tabs as an iOS
/// navigation list: Account, General, Appearance, Notifications, Machines,
/// Harnesses, MCPs, and Skills. Machine management (the old home-screen
/// machine picker) lives in Machines.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CloudAccountScreen()
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                }
                Section {
                    NavigationLink {
                        GeneralSettingsScreen()
                    } label: {
                        Label("General", systemImage: "gearshape")
                    }
                    NavigationLink {
                        AppearanceSettingsScreen()
                    } label: {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                    NavigationLink {
                        NotificationsSettingsScreen()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                }
                Section {
                    NavigationLink {
                        MachinesSettingsScreen()
                    } label: {
                        Label("Machines", systemImage: "desktopcomputer")
                    }
                } footer: {
                    Text("Harnesses, MCPs, and skills live on each machine — open a machine to manage them.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Account

/// Codevisor Cloud account: sign in via the browser handoff, see every
/// machine connected to the account, rename or disconnect them, and (under
/// Advanced) point the app at a self-hosted instance — the iOS mirror of the
/// macOS Settings → Account pane.
private struct CloudAccountScreen: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var signIn = CloudSignInCoordinator()
    @State private var isSigningIn = false
    @State private var serverURLText = ""
    @State private var serverError: String?
    @State private var isConnectingServer = false
    @State private var renaming: CloudMachine?
    @State private var renameText = ""
    @State private var removing: CloudMachine?

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
            Text("“\(machine.name)” will be signed out of your account. Nothing on the machine itself is changed — run codevisor auth login there to reconnect it.")
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
                InlineCodeText("No machines connected yet. Run `codevisor auth login` on a machine to connect it to your account.")
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
            HStack(spacing: 5) {
                Circle()
                    .fill(machine.online ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(machine.online ? "Online" : "Offline")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                return "Using self-hosted server “\(instance)” at \(custom.absoluteString). Connecting to a different server signs you out."
            }
            return "Using self-hosted server \(custom.absoluteString). Connecting to a different server signs you out."
        }
        return "Using the default Codevisor Cloud. Enter the URL of a self-hosted instance to use it instead — connecting signs you out of the current server."
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

/// Owns the ASWebAuthenticationSession for the browser sign-in and anchors it
/// to the key window. Sign-in state is shared with Safari on purpose
/// (`prefersEphemeralWebBrowserSession = false`) so a returning user doesn't
/// re-enter GitHub credentials. Internal (not private) so onboarding's
/// sign-in affordance can reuse it.
@MainActor
final class CloudSignInCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// The callback scheme for the browser handoff. iOS registers both
    /// `codevisor` and `codevisor-dev` (a dev build can handle links minted
    /// for production installs); prefer the scheme matching this build so the
    /// handoff round-trips into the right place.
    static var callbackScheme: String {
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] } ?? []
        let preferred = CodevisorAppVariant.isDevelopment ? "codevisor-dev" : "codevisor"
        if schemes.contains(preferred) { return preferred }
        return schemes.first { $0.hasPrefix("codevisor") } ?? preferred
    }

    /// Cancellation (the user closed the sheet) completes with nil.
    func start(
        url: URL,
        callbackScheme: String,
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        session?.cancel()
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme
        ) { callbackURL, error in
            Task { @MainActor in
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    if !cancelled {
                        Log.cloud.error("Cloud sign-in session failed: \(String(describing: error), privacy: .public)")
                    }
                    completion(nil)
                    return
                }
                completion(callbackURL)
            }
        }
        session.prefersEphemeralWebBrowserSession = false
        session.presentationContextProvider = self
        self.session = session
        session.start()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // This must return synchronously and is requested on the main thread;
        // the `main.sync` fallback only guards against a stray off-main
        // request trapping `MainActor.assumeIsolated`.
        let anchor: @MainActor () -> ASPresentationAnchor = {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
        if Thread.isMainThread {
            return MainActor.assumeIsolated(anchor)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(anchor)
        }
    }
}

// MARK: - General

private struct GeneralSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingDelete = false

    var body: some View {
        List {
            Section {
                Toggle(
                    "Share usage analytics",
                    isOn: Binding(
                        get: { environment.settings.shareAnalytics },
                        set: { environment.setShareAnalytics($0) }
                    )
                )
                Toggle(
                    "Send crash and error reports",
                    isOn: Binding(
                        get: { environment.settings.shareCrashReports },
                        set: { environment.setShareCrashReports($0) }
                    )
                )
            } header: {
                Text("Privacy")
            } footer: {
                Text("Helps improve Codevisor. Never includes your code or conversations.")
            }
            Section {
                Button("Delete All Data", role: .destructive) {
                    isConfirmingDelete = true
                }
            } footer: {
                Text("Removes this device's paired machines and local state. Nothing on your machines is changed.")
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete all local data?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                environment.deleteAllData()
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        List {
            Section("Mode") {
                Picker(
                    "Appearance",
                    selection: Binding(
                        get: { environment.settings.settings.themeMode },
                        set: { environment.settings.setThemeMode($0) }
                    )
                ) {
                    Text("Light").tag(ThemeMode.light)
                    Text("Dark").tag(ThemeMode.dark)
                    Text("System").tag(ThemeMode.system)
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Notifications

private struct NotificationsSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var authorization: UNAuthorizationStatus = .notDetermined

    var body: some View {
        List {
            Section {
                Toggle(
                    "Chat notifications",
                    isOn: Binding(
                        get: { environment.settings.settings.notificationsEnabled },
                        set: { environment.settings.setNotificationsEnabled($0) }
                    )
                )
            } footer: {
                Text("Get notified when a chat finishes or needs your input.")
            }
            Section("Delivery") {
                Toggle(
                    "Show notifications when Codevisor isn't active",
                    isOn: Binding(
                        get: { environment.settings.settings.systemNotificationsEnabled },
                        set: { environment.settings.setSystemNotificationsEnabled($0) }
                    )
                )
                if authorization == .notDetermined {
                    Button("Allow System Notifications…") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound, .badge])
                            await refreshAuthorization()
                        }
                    }
                } else if authorization == .denied {
                    Button("Open Notification Settings…") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            Section("Sounds") {
                Toggle(
                    "Play sounds",
                    isOn: Binding(
                        get: { environment.settings.settings.notificationSoundsEnabled },
                        set: { environment.settings.setNotificationSoundsEnabled($0) }
                    )
                )
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshAuthorization() }
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }
}

// MARK: - Machines

/// Machine management: the paired remote machines (never the on-device
/// "local" pseudo-machine — this client has no local server). Each machine
/// nests its own scoped settings: status, harnesses, MCPs, skills.
struct MachinesSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isAddingMachine = false
    @State private var isAddingDevelopmentMachine = false
    @State private var developmentError: String?
    @State private var discovery = TailnetMachineDiscovery()
    @State private var discoveredTarget: TailnetMachineDiscovery.Discovered?

    private var machines: MachineController { environment.machines }

    private var remoteMachines: [CodevisorMachine] {
        machines.allMachines.filter { !$0.isLocal }
    }

    var body: some View {
        List {
            Section {
                ForEach(remoteMachines, id: \.id) { machine in
                    NavigationLink {
                        MachineDetailScreen(machineId: machine.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: machine.resolvedAppearance.symbolName)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.name)
                                Text(machines.statusByMachineId[machine.id]?.label ?? machine.baseURL.absoluteString)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if machine.id == machines.selectedMachineId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } footer: {
                InlineCodeText("Run `codevisor setup` on a machine to print its address and token.")
            }
            if !discovery.discovered.isEmpty {
                Section {
                    ForEach(discovery.discovered) { machine in
                        discoveredRow(machine)
                    }
                } header: {
                    Text("On Your Tailnet")
                } footer: {
                    Text("Codevisor servers found on your tailnet. Adding one still needs its connection token.")
                }
            }
            Section {
                Button {
                    isAddingMachine = true
                } label: {
                    Label("Add Machine…", systemImage: "plus")
                }
            }
            if let devRemote = CodevisorAppVariant.developmentRemote,
               developmentMachine(devRemote) == nil {
                developmentSection(devRemote)
            }
        }
        .navigationTitle("Machines")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingMachine) {
            AddMachineSheet()
        }
        .sheet(item: $discoveredTarget) { machine in
            AddMachineSheet(initialHost: machine.host, initialName: machine.name)
        }
        // Discover only while this screen is on screen — no background polling.
        .task {
            while !Task.isCancelled {
                await discovery.refresh(machines: machines)
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // A removed machine may be discoverable again (and a just-added one
        // must leave the list) — refresh whenever the machine list changes.
        .onChange(of: machines.machines.map(\.id)) { _, _ in
            Task { await discovery.refresh(machines: machines) }
        }
    }

    private func discoveredRow(_ machine: TailnetMachineDiscovery.Discovered) -> some View {
        Button {
            discoveredTarget = machine
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.name)
                        .foregroundStyle(.primary)
                    Text("\(machine.host) · Codevisor \(machine.version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
    }

    /// Dev-only shortcut, as on macOS: one tap adds the dev remote that
    /// `bun run dev:ios` started, no token entry. Hidden once it's paired —
    /// remove it like any other machine from its detail page.
    private func developmentSection(_ remote: CodevisorAppVariant.DevelopmentRemote) -> some View {
        Section {
            Button {
                Task { await addDevelopmentMachine(remote) }
            } label: {
                Label("Add Development Machine", systemImage: "bolt.fill")
            }
            .disabled(isAddingDevelopmentMachine)
        } header: {
            Text("Development")
        } footer: {
            if let developmentError {
                Text(developmentError)
                    .foregroundStyle(.red)
            } else {
                Text("\(remote.name) at \(remote.hostWithPort), started by bun run dev:ios.")
            }
        }
    }

    /// The registered machine matching the dev remote (by host + port), if
    /// it has been added — the section hides itself once paired.
    private func developmentMachine(_ remote: CodevisorAppVariant.DevelopmentRemote) -> CodevisorMachine? {
        machines.machines.first { machine in
            machine.baseURL.host() == remote.host
                && (machine.baseURL.port ?? CodevisorAppVariant.productionPort) == remote.port
        }
    }

    private func addDevelopmentMachine(_ remote: CodevisorAppVariant.DevelopmentRemote) async {
        isAddingDevelopmentMachine = true
        developmentError = nil
        defer { isAddingDevelopmentMachine = false }
        do {
            let added = try await machines.addRemoteValidating(
                host: remote.hostWithPort,
                name: remote.name,
                token: remote.token
            )
            machines.selectMachine(added.id)
            await environment.prepareSelectedMachine()
        } catch {
            developmentError = ErrorReporter.userFacingMessage(for: error)
        }
    }
}

/// One machine's page: connection info and the settings scoped to it —
/// harnesses, MCPs, and skills all live on the machine, so they're nested
/// here rather than floating at the top level.
private struct MachineDetailScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let machineId: String

    @State private var isRenaming = false
    @State private var renameText = ""

    private var machines: MachineController { environment.machines }
    private var machine: CodevisorMachine? { machines.machine(for: machineId) }

    var body: some View {
        List {
            if let machine {
                Section {
                    LabeledContent("Endpoint", value: machine.baseURL.absoluteString)
                    LabeledContent(
                        "Status",
                        value: machines.statusByMachineId[machine.id]?.label ?? "Connecting…"
                    )
                    if machine.id != machines.selectedMachineId {
                        Button("Use This Machine") {
                            machines.selectMachine(machine.id)
                            Task { await environment.prepareSelectedMachine() }
                        }
                    }
                }
                Section("On This Machine") {
                    NavigationLink {
                        HarnessesSettingsScreen(client: machines.client(for: machine.id))
                    } label: {
                        Label("Harnesses", systemImage: "cpu")
                    }
                    NavigationLink {
                        McpSettingsScreen(client: machines.client(for: machine.id))
                    } label: {
                        Label("MCPs", systemImage: "puzzlepiece.extension")
                    }
                    NavigationLink {
                        SkillsSettingsScreen(client: machines.client(for: machine.id))
                    } label: {
                        Label("Skills", systemImage: "book.closed")
                    }
                }
                Section {
                    Button("Rename…") {
                        renameText = machine.name
                        isRenaming = true
                    }
                    Button("Remove Machine…", role: .destructive) {
                        try? machines.removeMachine(machine.id)
                        dismiss()
                    }
                } footer: {
                    Text("Codevisor forgets this machine. Nothing on the machine itself is changed.")
                }
            }
        }
        .navigationTitle(machine?.name ?? "Machine")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Machine", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                try? machines.renameMachine(machineId, to: renameText)
                isRenaming = false
            }
            Button("Cancel", role: .cancel) { isRenaming = false }
        }
    }
}

/// Manual pairing: address + token, validated against the server before the
/// machine is saved (the iOS mirror of the macOS Add Remote Machine form).
/// Styled like the system "Join Wi-Fi Network" sheet: circular close/confirm
/// buttons, a centered tinted glyph, a leading large title, and label-led
/// form rows. The QR/deeplink flow covers the common path; this is the
/// fallback for typing coordinates from `codevisor setup`. Shared with
/// onboarding.
struct AddMachineSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var host: String
    @State private var name: String
    @State private var token = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    /// Prefill support for the tailnet-discovery rows; the manual add flow
    /// uses the empty defaults.
    init(initialHost: String = "", initialName: String = "") {
        _host = State(initialValue: initialHost)
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    labeledField("Address") {
                        TextField("Host or host:port", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
                Section {
                    labeledField("Name") {
                        TextField("Optional", text: $name)
                    }
                    labeledField("Token") {
                        SecureField("Connection token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    InlineCodeText("Run `codevisor token` on the machine, or copy it from the `codevisor setup` output.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// The Join-Wi-Fi-style top area: X and ✓ in circles, a centered tinted
    /// glyph, and the leading large title.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .scaledFrame(width: 22, height: 22, relativeTo: .title3)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Cancel")
                Spacer()
                Button {
                    add()
                } label: {
                    Group {
                        if isAdding {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark")
                                .font(.title3.weight(.semibold))
                        }
                    }
                    .scaledFrame(width: 22, height: 22, relativeTo: .title3)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(host.isEmpty || isAdding)
                .accessibilityLabel("Add")
            }
            Image(systemName: "desktopcomputer")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            Text("Add Machine")
                .font(.title.bold())
                .padding(.top, 28)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// A native settings form row: leading label, then the field inline.
    private func labeledField(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 16) {
            Text(label)
            field()
        }
    }

    private func add() {
        isAdding = true
        errorMessage = nil
        Task {
            do {
                let machine = try await environment.machines.addRemoteValidating(
                    host: host,
                    name: name.isEmpty ? nil : name,
                    token: token.isEmpty ? nil : token
                )
                environment.machines.selectMachine(machine.id)
                await environment.prepareSelectedMachine()
                dismiss()
            } catch {
                errorMessage = ErrorReporter.userFacingMessage(for: error)
                isAdding = false
            }
        }
    }
}

// MARK: - Harnesses

private struct HarnessesSettingsScreen: View {
    let client: any CodevisorServerClienting
    @State private var harnesses: [ServerHarness] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var installed: [ServerHarness] {
        harnesses.filter { $0.readiness.state != "notInstalled" }
    }

    private var notInstalled: [ServerHarness] {
        harnesses.filter { $0.readiness.state == "notInstalled" }
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                Section("Installed") {
                    ForEach(installed, id: \.id) { harness in
                        harnessRow(harness)
                    }
                }
                if !notInstalled.isEmpty {
                    Section("Not Installed") {
                        ForEach(notInstalled, id: \.id) { harness in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(harness.name)
                                if let hint = harness.installHint {
                                    Text(hint)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Harnesses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh harnesses")
            }
        }
        .task { await load() }
    }

    private func harnessRow(_ harness: ServerHarness) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(harness.name)
                if let auth = harness.auth, auth.state != "authenticated" {
                    Text("Sign in on your machine to use")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Toggle(
                "Enable \(harness.name)",
                isOn: Binding(
                    get: { harness.enabled },
                    set: { enabled in
                        Task {
                            _ = try? await client.setHarnessEnabled(
                                id: harness.id, enabled: enabled
                            )
                            await load()
                        }
                    }
                )
            )
            .labelsHidden()
        }
    }

    private func load() async {
        do {
            harnesses = try await client.listHarnesses()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        isLoading = false
    }
}

// MARK: - MCPs

private struct McpSettingsScreen: View {
    let client: any CodevisorServerClienting
    @State private var servers: [ServerMcpServer] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if servers.isEmpty {
                Text("No MCP servers managed by Codevisor yet.")
                    .foregroundStyle(.secondary)
            } else {
                Section("MCP Servers") {
                    ForEach(servers, id: \.id) { server in
                        serverRow(server)
                    }
                }
            }
        }
        .navigationTitle("MCPs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func serverRow(_ server: ServerMcpServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                    if server.kind == "browserUse" || server.kind == "computerUse" {
                        Text("Built-in")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(server.connectionState)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Enable \(server.name)",
                isOn: Binding(
                    get: { server.enabled },
                    set: { enabled in
                        Task {
                            _ = try? await client.setMcpServerEnabled(
                                id: server.id, enabled: enabled
                            )
                            await load()
                        }
                    }
                )
            )
            .labelsHidden()
        }
        .contextMenu {
            if server.canRemove != false {
                Button(role: .destructive) {
                    Task {
                        try? await client.removeMcpServer(id: server.id)
                        await load()
                    }
                } label: {
                    Label("Remove…", systemImage: "trash")
                }
            }
        }
    }

    private func load() async {
        do {
            servers = try await client.listMcpServers()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        isLoading = false
    }
}

// MARK: - Skills

private struct SkillsSettingsScreen: View {
    let client: any CodevisorServerClienting
    @State private var scan: ServerSkillsScan?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if let scan {
                if scan.global.isEmpty {
                    ContentUnavailableView {
                        Label("No Skills", systemImage: "book.closed")
                    } description: {
                        Text("Skills are reusable instruction sets shared with your coding agents.")
                    }
                } else {
                    Section("Global Skills") {
                        ForEach(scan.global, id: \.id) { skill in
                            skillRow(skill)
                        }
                    }
                }
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sync") {
                    Task {
                        scan = try? await client.syncSkills(directoryNames: nil)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func skillRow(_ skill: ServerGlobalSkill) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(skill.name)
            if let description = skill.description, !description.isEmpty {
                // No detail screen exists, so the row is the only place this
                // description can be read — let it wrap fully.
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task {
                    scan = try? await client.removeSkill(directoryName: skill.directoryName)
                }
            } label: {
                Label("Remove…", systemImage: "trash")
            }
        }
    }

    private func load() async {
        do {
            scan = try await client.listSkills()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        isLoading = false
    }
}

// MARK: - Inline code styling

/// Styles the backticked runs of a hint string like chat history's inline
/// code chips — monospaced over a soft rounded background — so commands read
/// as code instead of just a font change. Uses the same TextRenderer
/// technique as StreamMarkdown's portable chip painter.
struct InlineCodeText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    /// Marks the code-span glyph runs so the renderer can find them.
    private struct ChipMarker: TextAttribute {}

    /// Paints a rounded chip behind every marked run, then draws the text.
    private struct ChipRenderer: TextRenderer {
        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            for line in layout {
                var chipRect: CGRect?
                func flush() {
                    if let rect = chipRect {
                        context.fill(
                            Path(roundedRect: rect.insetBy(dx: -3, dy: -1), cornerRadius: 5),
                            with: .color(Color.secondary.opacity(0.18))
                        )
                    }
                    chipRect = nil
                }
                for run in line {
                    if run[ChipMarker.self] != nil {
                        let rect = run.typographicBounds.rect
                        chipRect = chipRect.map { $0.union(rect) } ?? rect
                    } else {
                        flush()
                    }
                }
                flush()
            }
            for line in layout {
                context.draw(line)
            }
        }
    }

    var body: some View {
        Array(text.components(separatedBy: "`").enumerated())
            .reduce(Text("")) { result, piece in
                if piece.offset.isMultiple(of: 2) {
                    return result + Text(piece.element)
                }
                return result
                    + Text(piece.element)
                        .font(.footnote.monospaced())
                        .customAttribute(ChipMarker())
            }
            .textRenderer(ChipRenderer())
    }
}
