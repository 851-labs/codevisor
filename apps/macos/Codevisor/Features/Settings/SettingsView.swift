import SwiftUI
import AppKit
import CodevisorCore
import os
import UniformTypeIdentifiers
import UserNotifications
import CodevisorUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case notifications
    case shortcuts
    case machines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .shortcuts: "Shortcuts"
        case .machines: "Machines"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .notifications: "bell"
        case .shortcuts: "keyboard"
        case .machines: "desktopcomputer"
        }
    }
}

/// A page pushed inside the Machines section's detail column. Every case
/// carries the machine it is scoped to, so a page keeps addressing its
/// machine even if the app's selected machine changes underneath the open
/// Settings window.
enum MachineSettingsRoute: Hashable {
    case machine(String)
    case harnesses(String)
    case mcps(String)
    case skills(String)
}

/// A place in Settings: the sidebar section plus any machine pages pushed
/// over it. The unit of the router's back/forward history.
struct SettingsLocation: Equatable {
    var tab: SettingsTab
    var machinesPath: [MachineSettingsRoute]
}

/// Routes programmatic Settings navigation (e.g. the sidebar's
/// "Manage machines…" opens Settings on the Machines section) and keeps the
/// Xcode-style back/forward history over every visited page.
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var selectedTab: SettingsTab = .general
    /// The Machines section's navigation stack (machine detail and its pages).
    var machinesPath: [MachineSettingsRoute] = []
    /// Pages behind and ahead of the current one. Every navigation — sidebar
    /// selection, push, deep link — lands the previous page in `backHistory`;
    /// going back moves the current page to `forwardHistory` (cleared again
    /// by the next normal navigation, like a browser).
    private(set) var backHistory: [SettingsLocation] = []
    private(set) var forwardHistory: [SettingsLocation] = []
    /// One-shot: set while back/forward applies a location so the change
    /// observer doesn't record time travel as a new navigation.
    @ObservationIgnored var suppressHistoryRecording = false
    /// Resolves the app's selected machine for deep links that don't carry
    /// one ("Manage Harnesses…" from a chat). Injected at app startup.
    @ObservationIgnored var selectedMachineIdProvider: () -> String? = { nil }

    var currentLocation: SettingsLocation {
        SettingsLocation(tab: selectedTab, machinesPath: machinesPath)
    }

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }

    /// Files the page just left into the back history. Called by the view's
    /// change observer for every user navigation.
    func recordNavigation(from previous: SettingsLocation) {
        backHistory.append(previous)
        if backHistory.count > 50 { backHistory.removeFirst() }
        forwardHistory.removeAll()
    }

    func goBack() {
        guard let target = backHistory.popLast() else { return }
        forwardHistory.append(currentLocation)
        apply(target)
    }

    func goForward() {
        guard let target = forwardHistory.popLast() else { return }
        backHistory.append(currentLocation)
        apply(target)
    }

    private func apply(_ location: SettingsLocation) {
        suppressHistoryRecording = true
        selectedTab = location.tab
        machinesPath = location.machinesPath
    }

    func showMachines() {
        machinesPath = []
        selectedTab = .machines
    }

    /// Opens the harnesses page of the given machine, defaulting to the
    /// app's selected machine.
    func showHarnesses(machineId: String? = nil) {
        selectedTab = .machines
        guard let id = machineId ?? selectedMachineIdProvider() else {
            machinesPath = []
            return
        }
        machinesPath = [.machine(id), .harnesses(id)]
    }
}

/// The native back/forward control (System Settings, Xcode): a `ControlGroup`
/// in the navigation control-group style. AppKit draws the grouped capsule,
/// divider, sizing, and disabled dimming.
private struct SettingsBackForwardControl: View {
    @Bindable private var router = SettingsRouter.shared

    var body: some View {
        ControlGroup {
            Button {
                router.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!router.canGoBack)
            .help("Back")
            .keyboardShortcut("[", modifiers: .command)

            Button {
                router.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!router.canGoForward)
            .help("Forward")
            .keyboardShortcut("]", modifiers: .command)
        }
        .controlGroupStyle(.navigation)
    }
}

/// Puts the back/forward control in the window toolbar. Applied to every
/// page in the detail column — the root panes and each pushed machine page —
/// so the control is always present.
private struct SettingsNavigationToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .navigation) {
                SettingsBackForwardControl()
            }
        }
    }
}

extension View {
    func settingsNavigationToolbar() -> some View {
        modifier(SettingsNavigationToolbar())
    }
}

/// The machine a Settings subtree is scoped to. Set at the root of a pushed
/// machine page; panes and their sheets resolve the server they talk to from
/// this, falling back to the app's selected machine (onboarding, previews).
private struct SettingsMachineIdKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsMachineId: String? {
        get { self[SettingsMachineIdKey.self] }
        set { self[SettingsMachineIdKey.self] = newValue }
    }
}

/// The app's Settings window (⌘, / Codevisor ▸ Settings…) in the modern
/// sidebar style (System Settings, Xcode 26): sections on the left, the
/// selected section's content on the right with push navigation for
/// per-item pages. Client-scoped sections (General, Appearance,
/// Notifications, Shortcuts) sit alongside Machines, which owns everything
/// scoped to a specific machine: its server, harnesses, MCP servers, and
/// skills.
struct SettingsView: View {
    @Bindable private var router = SettingsRouter.shared
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 240)
            // System Settings keeps its sidebar fixed; a collapse control
            // would just leave an empty content window here.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack(path: $router.machinesPath) {
                detailRoot
                    .settingsNavigationToolbar()
                    .navigationDestination(for: MachineSettingsRoute.self) { route in
                        destination(for: route)
                    }
            }
        }
        // Every navigation (sidebar selection, push, pop, deep link) files
        // the previous page into the history — except when back/forward is
        // the thing navigating.
        .onChange(of: router.currentLocation) { previous, _ in
            if router.suppressHistoryRecording {
                router.suppressHistoryRecording = false
                return
            }
            router.recordNavigation(from: previous)
        }
        .frame(minWidth: 780, idealWidth: 780, minHeight: 560, idealHeight: 560)
        // One-row toolbar with the back button and title inline (the Settings
        // scene ignores the windowToolbarStyle scene modifier).
        .settingsWindowToolbarStyle()
        // When themed, drop the grouped forms' own backdrop so the theme
        // surface (painted by ThemedRoot) shows through; system themes keep
        // the native look.
        .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
        .themedToolbarBackground(theme, role: .content)
    }

    /// Selecting a sidebar section resets any machine pages pushed over the
    /// previous section's content.
    private var sidebarSelection: Binding<SettingsTab?> {
        Binding(
            get: { router.selectedTab },
            set: { tab in
                guard let tab else { return }
                if tab != router.selectedTab { router.machinesPath = [] }
                router.selectedTab = tab
            }
        )
    }

    @ViewBuilder
    private var detailRoot: some View {
        switch router.selectedTab {
        case .general:
            GeneralSettingsView()
                .navigationTitle("General")
        case .appearance:
            AppearanceSettingsView()
                .navigationTitle("Appearance")
        case .notifications:
            NotificationsSettingsView()
                .navigationTitle("Notifications")
        case .shortcuts:
            ShortcutsSettingsView()
                .navigationTitle("Shortcuts")
        case .machines:
            MachinesSettingsView()
                .navigationTitle("Machines")
        }
    }

    /// The pushed machine pages. Each subtree is pinned to its machine via
    /// `settingsMachineId`, so the panes and every sheet they present keep
    /// talking to that machine regardless of the app's selected machine.
    /// The system back button is hidden everywhere — the persistent
    /// back/forward pair in the toolbar is the one navigation control.
    @ViewBuilder
    private func destination(for route: MachineSettingsRoute) -> some View {
        Group {
            switch route {
            case let .machine(id):
                MachineSettingsDetailView(machineId: id)
                    .environment(\.settingsMachineId, id)
            case let .harnesses(id):
                HarnessesSettingsView()
                    .navigationTitle("Harnesses")
                    .environment(\.settingsMachineId, id)
            case let .mcps(id):
                McpSettingsView()
                    .navigationTitle("MCP Servers")
                    .environment(\.settingsMachineId, id)
            case let .skills(id):
                SkillsSettingsView()
                    .navigationTitle("Skills")
                    .environment(\.settingsMachineId, id)
            }
        }
        .navigationBarBackButtonHidden(true)
        .settingsNavigationToolbar()
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
                            .frame(width: 20, height: 20)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: Typography.IconSize.compact, weight: .semibold))
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
                        .frame(width: 20, height: 20)
                    Image(systemName: "play.fill")
                        .font(.system(size: Typography.IconSize.compact, weight: .semibold))
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
            Log.attachments.error(
                "Deleting custom sound \(sound.path, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
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
            settings.actionRequiredSoundPath,
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

/// General app settings: updates, privacy, and local data. Everything scoped
/// to a machine (server status, remote access) lives in Settings ▸ Machines.
struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var showingConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: alphaUpdatesEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Alpha updates")
                        Text("Receive Alpha builds before stable releases.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                Text("Updates")
            }

            Section {
                Toggle("Share usage analytics", isOn: shareAnalytics)
                    .toggleStyle(.switch)
                Toggle("Send crash and error reports", isOn: shareCrashReports)
                    .toggleStyle(.switch)
            } header: {
                Text("Privacy")
            } footer: {
                Text(
                    "Anonymous. Prompts, responses, code, file paths, browser content, and terminal commands are never included."
                )
            }

            Section("Data") {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Delete all data")
                        Text("Removes all projects, chats, and settings, then restarts setup.")
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
    }

    private var shareAnalytics: Binding<Bool> {
        Binding(
            get: { environment.settings.shareAnalytics },
            set: { environment.setShareAnalytics($0) }
        )
    }

    private var shareCrashReports: Binding<Bool> {
        Binding(
            get: { environment.settings.shareCrashReports },
            set: { environment.setShareCrashReports($0) }
        )
    }

    private var alphaUpdatesEnabled: Binding<Bool> {
        Binding(
            get: { environment.settings.alphaUpdatesEnabled },
            set: { enabled in
                environment.setAlphaUpdatesEnabled(enabled)
                Task { await environment.appUpdate.checkForUpdates() }
            }
        )
    }

}

#Preview("Settings") {
    SettingsView()
        .environment(AppEnvironment.preview())
}
