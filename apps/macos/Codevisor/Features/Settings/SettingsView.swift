import SwiftUI
import AppKit
import CodevisorCore
import os
import UniformTypeIdentifiers
import UserNotifications

enum SettingsTab: String {
    case general
    case appearance
    case notifications
    case machines
    case harnesses
    case mcps
}

/// Routes programmatic Settings navigation (e.g. the sidebar's
/// "Manage machines…" opens Settings on the Machines tab).
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var selectedTab: SettingsTab = .general
}

/// The app's Settings window (⌘, / Codevisor ▸ Settings…), with General,
/// Appearance, Machines, and Harnesses tabs in the standard macOS
/// preferences style.
struct SettingsView: View {
    @Bindable private var router = SettingsRouter.shared
    @Environment(\.theme) private var theme

    var body: some View {
        TabView(selection: $router.selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsTab.appearance)
            NotificationsSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)
            MachinesSettingsView()
                .tabItem { Label("Machines", systemImage: "desktopcomputer") }
                .tag(SettingsTab.machines)
            HarnessesSettingsView()
                .tabItem { Label("Harnesses", systemImage: "cpu") }
                .tag(SettingsTab.harnesses)
            McpSettingsView()
                .tabItem { Label("MCPs", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.mcps)
        }
        .frame(width: 580, height: 500)
        // When themed, drop the grouped forms' own backdrop so the theme
        // surface (painted by ThemedRoot) shows through, and paint the tab
        // strip opaquely on-theme; system themes keep the native look.
        .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
        .themedToolbarBackground(theme, surface: theme.windowBackground)
    }
}

/// Device-local chat attention settings. The master switch controls both
/// background banners and foreground sounds; subordinate switches let people
/// tune either presentation without duplicating macOS-wide Focus controls.
struct NotificationsSettingsView: View {
    /// A failed custom-sound action (import/delete), pending display in an alert.
    private struct SoundActionError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var soundChoices: [SystemSoundChoice] = []
    @State private var testMessage: String?
    @State private var showingSoundImporter = false
    /// Which sound row opened the importer, so the imported sound is
    /// auto-assigned there; nil when importing from the Custom Sounds list.
    @State private var soundImportTarget: ChatAttentionKind?
    @State private var soundError: SoundActionError?

    private var settings: AppSettings { environment.settings.settings }
    private var customSoundStore: CustomSoundStore { CustomSoundStore() }
    private var customSoundChoices: [SystemSoundChoice] { soundChoices.filter(\.isCustom) }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: notificationsEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Chat notifications")
                        Text("Get notified when a chat finishes or needs your input.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section {
                Toggle("Show notifications when Codevisor isn't active", isOn: systemNotificationsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!settings.notificationsEnabled)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("System notifications")
                        Text(authorizationDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(authorizationButtonTitle) {
                        handleAuthorizationButton()
                    }
                    .settingsActionTint(theme)
                    .disabled(!settings.notificationsEnabled || !settings.systemNotificationsEnabled)
                }
            } header: {
                Text("Delivery")
            }

            Section {
                Toggle("Play sounds", isOn: soundsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!settings.notificationsEnabled)

                soundRow(
                    title: "Chat finished",
                    selection: chatFinishedSound,
                    kind: .finished
                )
                .disabled(!settings.notificationsEnabled || !settings.notificationSoundsEnabled)

                soundRow(
                    title: "Action required",
                    selection: actionRequiredSound,
                    kind: .actionRequired
                )
                .disabled(!settings.notificationsEnabled || !settings.notificationSoundsEnabled)
            } header: {
                Text("Sounds")
            }

            Section {
                if customSoundChoices.isEmpty {
                    Text("No custom sounds")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customSoundChoices) { sound in
                        customSoundRow(sound)
                    }
                }
                Button("Add Sound…") {
                    soundImportTarget = nil
                    showingSoundImporter = true
                }
                .settingsActionTint(theme)
            } header: {
                Text("Custom Sounds")
            }

            Section("Test") {
                HStack {
                    Button("Send Test Notification") {
                        Task { await sendTestNotification() }
                    }
                    .settingsActionTint(theme)
                    Spacer()
                    if let testMessage {
                        Text(testMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .settingsPaneFormStyle(theme)
        .fileImporter(
            isPresented: $showingSoundImporter,
            allowedContentTypes: [.audio]
        ) { result in
            handleSoundImport(result)
        }
        .alert(
            soundError?.title ?? "",
            isPresented: Binding(
                get: { soundError != nil },
                set: { if !$0 { soundError = nil } }
            ),
            presenting: soundError
        ) { _ in
            Button("OK", role: .cancel) {}
                .settingsActionTint(theme)
        } message: { error in
            Text(error.message)
        }
        .task {
            refreshSoundChoices()
            await refreshAuthorizationStatus()
        }
    }

    private var notificationsEnabled: Binding<Bool> {
        Binding(
            get: { settings.notificationsEnabled },
            set: { enabled in
                environment.settings.setNotificationsEnabled(enabled)
                if enabled, settings.systemNotificationsEnabled {
                    Task {
                        await ChatNotificationManager.shared.prepareAuthorizationIfNeeded()
                        await refreshAuthorizationStatus()
                    }
                }
            }
        )
    }

    private var systemNotificationsEnabled: Binding<Bool> {
        Binding(
            get: { settings.systemNotificationsEnabled },
            set: { enabled in
                environment.settings.setSystemNotificationsEnabled(enabled)
                if enabled {
                    Task {
                        await ChatNotificationManager.shared.prepareAuthorizationIfNeeded()
                        await refreshAuthorizationStatus()
                    }
                }
            }
        )
    }

    private var soundsEnabled: Binding<Bool> {
        Binding(
            get: { settings.notificationSoundsEnabled },
            set: { environment.settings.setNotificationSoundsEnabled($0) }
        )
    }

    private var chatFinishedSound: Binding<String> {
        Binding(
            get: { settings.chatFinishedSoundPath },
            set: { environment.settings.setChatFinishedSoundPath($0) }
        )
    }

    private var actionRequiredSound: Binding<String> {
        Binding(
            get: { settings.actionRequiredSoundPath },
            set: { environment.settings.setActionRequiredSoundPath($0) }
        )
    }

    private func soundRow(
        title: String,
        selection: Binding<String>,
        kind: ChatAttentionKind
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(theme.textPrimary)
            Spacer(minLength: 20)
            Menu {
                let custom = customSoundChoices
                let system = soundChoices.filter { !$0.isCustom }
                if custom.isEmpty {
                    soundMenuItems(system, selection: selection)
                    Divider()
                    Button("Add Custom Sound…") {
                        soundImportTarget = kind
                        showingSoundImporter = true
                    }
                } else {
                    Section("System") {
                        soundMenuItems(system, selection: selection)
                    }
                    Section("Custom") {
                        soundMenuItems(custom, selection: selection)
                        Button("Add Custom Sound…") {
                            soundImportTarget = kind
                            showingSoundImporter = true
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(soundName(for: selection.wrappedValue))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    ZStack {
                        Circle()
                            .fill(theme.cardHoverBackground)
                            .frame(width: 18, height: 18)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                    }
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)

            Button {
                ChatNotificationManager.shared.playPreview(kind: kind)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(theme.textSecondary.opacity(0.75), lineWidth: 1)
                        .frame(width: 18, height: 18)
                    Image(systemName: "play.fill")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Play \(title.lowercased()) sound")
            .accessibilityLabel("Test \(title.lowercased()) sound")
        }
    }

    @ViewBuilder
    private func soundMenuItems(_ choices: [SystemSoundChoice], selection: Binding<String>) -> some View {
        ForEach(choices) { sound in
            Button {
                selection.wrappedValue = sound.path
            } label: {
                if sound.path == selection.wrappedValue {
                    Label(sound.name, systemImage: "checkmark")
                } else {
                    Text(sound.name)
                }
            }
        }
    }

    private func customSoundRow(_ sound: SystemSoundChoice) -> some View {
        HStack {
            Text(sound.name)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                ChatNotificationManager.shared.playSample(at: sound.path)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .settingsActionTint(theme)
            .help("Play \(sound.name)")
            .accessibilityLabel("Play \(sound.name)")
            Button {
                deleteCustomSound(sound)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .settingsActionTint(theme)
            .help("Remove this sound")
            .accessibilityLabel("Remove \(sound.name)")
        }
    }

    private func handleSoundImport(_ result: Result<URL, any Error>) {
        let target = soundImportTarget
        soundImportTarget = nil
        guard case let .success(url) = result else { return }
        do {
            let imported = try customSoundStore.importSound(from: url)
            refreshSoundChoices()
            switch target {
            case .finished:
                environment.settings.setChatFinishedSoundPath(imported.path)
            case .actionRequired:
                environment.settings.setActionRequiredSoundPath(imported.path)
            case nil:
                break
            }
            // Audition the converted sound right away, so a bad pick is
            // obvious while the user is still in Settings.
            ChatNotificationManager.shared.playSample(at: imported.path)
        } catch {
            Log.attachments.error("Importing custom sound failed: \(String(describing: error), privacy: .public)")
            soundError = SoundActionError(
                title: "Couldn't Add the Sound",
                message: ErrorReporter.userFacingMessage(for: error)
            )
        }
    }

    private func deleteCustomSound(_ sound: SystemSoundChoice) {
        do {
            try customSoundStore.deleteSound(at: URL(fileURLWithPath: sound.path))
        } catch {
            Log.attachments.error("Deleting custom sound \(sound.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            soundError = SoundActionError(
                title: "Couldn't Remove the Sound",
                message: ErrorReporter.userFacingMessage(for: error)
            )
            return
        }
        // A notification kind pointing at the deleted file falls back to the
        // default system sound instead of silently beeping later.
        if settings.chatFinishedSoundPath == sound.path {
            environment.settings.setChatFinishedSoundPath(AppSettings.defaultNotificationSoundPath)
        }
        if settings.actionRequiredSoundPath == sound.path {
            environment.settings.setActionRequiredSoundPath(AppSettings.defaultNotificationSoundPath)
        }
        refreshSoundChoices()
    }

    private func soundName(for path: String) -> String {
        soundChoices.first { $0.path == path }?.name
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private var authorizationDescription: String {
        switch authorizationStatus {
        case .notDetermined: "Codevisor hasn't asked for permission yet."
        case .denied: "Off in System Settings."
        case .authorized, .provisional: "Allowed by macOS."
        @unknown default: "Managed by macOS."
        }
    }

    private var authorizationButtonTitle: String {
        switch authorizationStatus {
        case .notDetermined: "Allow…"
        default: "Notification Settings…"
        }
    }

    private func handleAuthorizationButton() {
        if authorizationStatus == .notDetermined {
            Task {
                _ = await ChatNotificationManager.shared.requestAuthorization()
                await refreshAuthorizationStatus()
            }
        } else {
            ChatNotificationManager.shared.openSystemNotificationSettings()
        }
    }

    private func refreshSoundChoices() {
        soundChoices = SystemSoundCatalog.availableSounds(including: [
            settings.chatFinishedSoundPath,
            settings.actionRequiredSoundPath
        ])
    }

    private func refreshAuthorizationStatus() async {
        authorizationStatus = await ChatNotificationManager.shared.authorizationStatus()
    }

    private func sendTestNotification() async {
        let sent = await ChatNotificationManager.shared.sendTestNotification(kind: .finished)
        testMessage = sent ? "Test sent" : "Notifications are off in System Settings"
        await refreshAuthorizationStatus()
        try? await Task.sleep(for: .seconds(3))
        testMessage = nil
    }
}

extension View {
    /// Keeps every top-level Settings pane on the same native grouped-Form
    /// layout and background behavior.
    func settingsPaneFormStyle(_ theme: Theme) -> some View {
        formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
    }

    /// Native macOS button and menu styles resolve their label color from the
    /// control tint, bypassing the themed root foreground. Keep their native
    /// interaction and disabled-state behavior while using the palette's
    /// accessible primary text color for custom themes.
    @ViewBuilder
    func settingsActionTint(_ theme: Theme) -> some View {
        if theme.isSystem {
            self
        } else {
            tint(theme.textPrimary)
        }
    }
}

/// General server, remote-access, privacy, and local-data settings.
struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var showingConfirmation = false
    @State private var serverStatus: ServerStatusModel?
    @State private var tokenCopied = false
    @State private var tokenError: String?

    var body: some View {
        Form {
            Section {
                serverStatusContent
            } header: {
                Text("Server")
            }

            Section {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connection token")
                        Text(tokenError ?? "Lets another device running Codevisor connect to this Mac.")
                            .font(.callout)
                            .foregroundStyle(tokenError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.statusWarn))
                    }
                    Spacer()
                    Button {
                        copyConnectionToken()
                    } label: {
                        if tokenCopied {
                            Label("Copied", systemImage: "checkmark")
                        } else {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    .settingsActionTint(theme)
                }
            } header: {
                Text("Remote Access")
            }

            Section {
                Toggle(isOn: shareAnalytics) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Share Codevisor analytics")
                        Text("Share anonymous usage and diagnostic data to help improve Codevisor. Prompts, responses, code, file paths, project names, and terminal commands are never included.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Privacy")
            }

            Section("Data") {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Delete all data")
                        Text("Removes projects, sessions, cached settings, and onboarding state, then restarts setup. Agent sessions are unaffected.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Delete…", role: .destructive) {
                        showingConfirmation = true
                    }
                    .settingsActionTint(theme)
                    .fixedSize()
                }
            }
        }
        .settingsPaneFormStyle(theme)
        .confirmationDialog(
            "Delete all Codevisor data?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                environment.deleteAllData()
            }
            .settingsActionTint(theme)
            Button("Cancel", role: .cancel) {}
                .settingsActionTint(theme)
        } message: {
            Text("This can't be undone. You'll be taken back through setup.")
        }
        .task(id: environment.machines.selectedMachineId) {
            serverStatus = ServerStatusModel(client: environment.serverClient)
            await refreshServerStatus()
        }
    }

    private var shareAnalytics: Binding<Bool> {
        Binding(
            get: { environment.settings.shareAnalytics },
            set: { environment.setShareAnalytics($0) }
        )
    }

    @ViewBuilder
    private var serverStatusContent: some View {
        if let serverStatus {
            if let errorMessage = serverStatus.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            settingsRow("Name", value: serverStatus.info?.name ?? "Local Codevisor")
            settingsRow("Version", value: serverStatus.info?.version ?? serverStatus.health?.version ?? "Checking…")
            settingsRow("Database", value: serverStatus.health?.database.capitalized ?? "Checking…")
            if let info = serverStatus.info {
                settingsRow("Endpoint", value: "\(info.bindHost) (\(info.kind))")
            }
            updateRow(serverStatus.update)

            Button {
                Task { await refreshServerStatus() }
            } label: {
                if serverStatus.isRefreshing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Refreshing…") }
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .settingsActionTint(theme)
            .disabled(serverStatus.isRefreshing)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking server…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingsRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func updateRow(_ update: ServerUpdateInfo?) -> some View {
        if let update {
            HStack {
                Label(
                    update.updateAvailable ? "Update available" : "Up to date",
                    systemImage: update.updateAvailable ? "arrow.down.circle" : "checkmark.circle"
                )
                Spacer()
                Text(update.updateAvailable
                    ? "\(update.currentVersion) → \(update.latestVersion)"
                    : update.currentVersion)
                    .foregroundStyle(.secondary)
            }
            if update.migrationState != "idle" {
                settingsRow("Migration", value: update.migrationState.capitalized)
            }
        } else {
            settingsRow("Update", value: "Checking…")
        }
    }

    private func refreshServerStatus() async {
        if serverStatus == nil {
            serverStatus = ServerStatusModel(client: environment.serverClient)
        }
        await serverStatus?.refresh()
    }

    /// Issues a fresh token from this Mac's server and puts it on the
    /// clipboard, for pasting into another device's Add Remote Machine form.
    private func copyConnectionToken() {
        Task {
            do {
                let token = try await environment.machines.issueLocalConnectionToken()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token, forType: .string)
                tokenError = nil
                tokenCopied = true
                try? await Task.sleep(for: .seconds(2))
                tokenCopied = false
            } catch {
                tokenError = "Couldn't issue a token: this Mac's server isn't running."
            }
        }
    }
}

/// Harnesses settings — toggle the installed ACP harnesses you want to use,
/// rescan for newly installed ones, and see which known harnesses aren't
/// installed yet.
struct HarnessesSettingsView: View {
    /// A failed enable/disable toggle, pending display in an alert.
    private struct ToggleError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    @State private var serverHarnesses: [ServerHarness] = []
    @State private var isScanning = true
    @State private var scanError: String?
    @State private var toggleError: ToggleError?
    @State private var showsNotInstalled = false
    @State private var authenticationHarness: ServerHarness?

    private var serverInstalled: [ServerHarness] { serverHarnesses.filter(\.isReady) }
    private var serverNotInstalled: [ServerHarness] { serverHarnesses.filter { !$0.isReady } }

    var body: some View {
        Form {
            Section {
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning for harnesses…").foregroundStyle(.secondary)
                    }
                } else if scanError != nil {
                    // Unreachable is not "nothing installed" — say so.
                    Text("Couldn't reach this machine's server. Check Settings → General, then refresh.")
                        .foregroundStyle(.secondary)
                } else if serverInstalled.isEmpty {
                    Text("No harnesses installed. Install Claude Code, Codex, or another ACP agent, then rescan.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(serverInstalled, id: \.id) { harness in
                        serverInstalledRow(harness)
                    }
                }
                Button {
                    Task { await scan() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .settingsActionTint(theme)
                .disabled(isScanning)
            } header: {
                Text("Installed")
            } footer: {
                Text("Enabled harnesses appear in the chat composer's harness picker.")
            }

            if !serverNotInstalled.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsNotInstalled) {
                        ForEach(serverNotInstalled, id: \.id) { harness in
                            serverNotInstalledRow(harness)
                        }
                    } label: {
                        Text("Not installed (\(serverNotInstalled.count))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .settingsPaneFormStyle(theme)
        .task { await scan() }
        .sheet(item: $authenticationHarness) { harness in
            HarnessAuthenticationView(harness: harness) { replaceServerHarness($0) }
        }
        .alert(
            toggleError?.title ?? "",
            isPresented: Binding(
                get: { toggleError != nil },
                set: { if !$0 { toggleError = nil } }
            ),
            presenting: toggleError
        ) { _ in
            Button("OK") {}
                .settingsActionTint(theme)
        } message: { error in
            Text(error.message)
        }
    }

    private func serverInstalledRow(_ harness: ServerHarness) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 15)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(harness.name)
                    Text(authStatus(harness))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if harness.auth != nil && !canUse(harness) {
                Button("Sign In…") { authenticationHarness = harness }
                    .settingsActionTint(theme)
            } else {
                if harness.auth != nil {
                    Button("Manage…") { authenticationHarness = harness }
                        .settingsActionTint(theme)
                }
                Toggle("Enable \(harness.name)", isOn: Binding(
                    get: { harness.enabled },
                    set: { enabled in Task { await setServerHarness(harness.id, enabled: enabled) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func canUse(_ harness: ServerHarness) -> Bool {
        harness.auth?.state == "authenticated" || harness.auth?.state == "notRequired"
    }

    private func authStatus(_ harness: ServerHarness) -> String {
        guard let auth = harness.auth else { return "Sign-in status unavailable" }
        let account = auth.accounts.first(where: { $0.id == auth.activeAccountId }) ?? auth.accounts.first
        switch auth.state {
        case "authenticated": return account?.email.map { "Signed in as \($0)" } ?? "Signed in"
        case "notRequired": return "No sign-in required"
        case "checking": return "Checking sign-in…"
        case "expired": return "Sign-in expired"
        case "error": return account?.detail ?? "Couldn't check sign-in"
        default: return "Not signed in"
        }
    }

    private func serverNotInstalledRow(_ harness: ServerHarness) -> some View {
        HarnessInstallHintRow(harness: harness)
    }

    /// Refresh = rescan: the server re-resolves its PATH first, so a CLI
    /// installed after server start is picked up without restarting anything.
    private func scan() async {
        isScanning = true
        defer { isScanning = false }
        let serverId = environment.machines.selectedMachineId
        do {
            serverHarnesses = try await environment.harnessService(for: serverId).rescanHarnesses()
            environment.harnessCatalogDidChange(onServer: serverId)
            scanError = nil
        } catch {
            serverHarnesses = []
            scanError = String(describing: error)
        }
    }

    private func setServerHarness(_ id: String, enabled: Bool) async {
        updateServerHarness(id, enabled: enabled)
        let serverId = environment.machines.selectedMachineId
        do {
            let updated = try await environment.machines.client(for: serverId)
                .setHarnessEnabled(id: id, enabled: enabled)
            replaceServerHarness(updated)
            environment.harnessCatalogDidChange(onServer: serverId)
        } catch {
            updateServerHarness(id, enabled: !enabled)
            Log.server.error("Setting harness \(id, privacy: .public) enabled=\(enabled, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            let name = serverHarnesses.first(where: { $0.id == id })?.name ?? id
            toggleError = ToggleError(
                title: enabled ? "Couldn't turn on \(name)" : "Couldn't turn off \(name)",
                message: ErrorReporter.userFacingMessage(for: error)
            )
        }
    }

    private func updateServerHarness(_ id: String, enabled: Bool) {
        guard let index = serverHarnesses.firstIndex(where: { $0.id == id }) else { return }
        serverHarnesses[index].enabled = enabled
    }

    private func replaceServerHarness(_ harness: ServerHarness) {
        guard let index = serverHarnesses.firstIndex(where: { $0.id == harness.id }) else { return }
        serverHarnesses[index] = harness
    }
}

#Preview("Settings") {
    SettingsView()
        .environment(AppEnvironment.preview())
}

#Preview("Harnesses") {
    HarnessesSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 520, height: 420)
}
