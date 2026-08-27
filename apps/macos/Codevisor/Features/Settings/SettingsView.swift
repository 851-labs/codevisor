import SwiftUI
import AppKit
import CodevisorCore
import os
import UniformTypeIdentifiers
import UserNotifications
import CodevisorUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, notifications
    case shortcuts
    // Fleet-synced config planes: the panes render the app's selected
    // machine, whose content converges with every other machine.
    case agents, mcps, skills, plugins
    case machines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .shortcuts: "Shortcuts"
        case .agents: "Harnesses"
        case .mcps: "MCP Servers"
        case .skills: "Skills"
        case .plugins: "Plugins"
        case .machines: "Machines"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .notifications: "bell"
        case .shortcuts: "keyboard"
        case .agents: "cpu"
        case .mcps: "puzzlepiece.extension"
        case .skills: "book.closed"
        case .plugins: "puzzlepiece"
        case .machines: "desktopcomputer"
        }
    }
}

/// A place in Settings — the sidebar section. The unit of the router's
/// back/forward history. Machine scoping lives inside each pane now: every
/// config pane is machine-first, so there are no pushed machine pages.
struct SettingsLocation: Equatable {
    var tab: SettingsTab
}

/// Routes programmatic Settings navigation (e.g. the sidebar's
/// "Manage machines…" opens Settings on the Machines section) and keeps the
/// Xcode-style back/forward history over every visited page.
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var selectedTab: SettingsTab = .general
    /// Machine pages pushed over the current pane (list row → machine page).
    var panePath: [MachinePaneRoute] = []
    /// Pages behind and ahead of the current one. Every navigation — sidebar
    /// selection, push, deep link — lands the previous page in `backHistory`;
    /// going back moves the current page to `forwardHistory` (cleared again
    /// by the next normal navigation, like a browser).
    private(set) var backHistory: [SettingsLocation] = []
    private(set) var forwardHistory: [SettingsLocation] = []
    /// One-shot: set while back/forward applies a location so the change
    /// observer doesn't record time travel as a new navigation.
    @ObservationIgnored var suppressHistoryRecording = false

    var currentLocation: SettingsLocation {
        SettingsLocation(tab: selectedTab)
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
        panePath = []
    }

    func showMachines() {
        selectedTab = .machines
    }

    /// Opens the Harnesses pane. Every machine's harnesses live right there
    /// as disclosures, so a deep link needs no machine-specific page — the
    /// machineId is accepted for callers that have one but changes nothing.
    func showHarnesses(machineId: String? = nil) {
        _ = machineId
        selectedTab = .agents
    }

    /// Opens the Plugins pane; same machine-first shape as showHarnesses.
    func showPlugins(machineId: String? = nil) {
        _ = machineId
        selectedTab = .plugins
    }

    /// A plugin source handed in from outside the settings window (the
    /// `codevisor://install-plugin` deeplink). The plugins pane consumes it
    /// and opens the install sheet — discover→consent still runs; a link can
    /// never skip the consent step.
    var pendingPluginInstallSource: String?
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

/// The machine a Settings subtree is scoped to. Set at the root of each
/// machine's disclosure content; sheets resolve the server they talk to from
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
    @Environment(AppEnvironment.self) private var environment
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
            .themedSurface(.sidebar)
            .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 240)
            .themedToolbarBackground(theme, role: .sidebar)
            // System Settings keeps its sidebar fixed; a collapse control
            // would just leave an empty content window here.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack(path: $router.panePath) {
                detailRoot
                    .settingsNavigationToolbar()
                    .navigationDestination(for: MachinePaneRoute.self) { route in
                        machinePage(for: route)
                    }
            }
            .themedToolbarBackground(theme, role: .content)
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
    }

    private var sidebarSelection: Binding<SettingsTab?> {
        Binding(
            get: { router.selectedTab },
            set: { tab in
                guard let tab else { return }
                if tab != router.selectedTab { router.panePath = [] }
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
        case .agents:
            HarnessesSettingsView()
                .navigationTitle("Harnesses")
        case .mcps:
            McpSettingsView()
                .navigationTitle("MCP Servers")
        case .skills:
            SkillsSettingsView()
                .navigationTitle("Skills")
        case .plugins:
            PluginsSettingsView()
                .navigationTitle("Plugins")
        case .machines:
            MachinesSettingsView()
                .navigationTitle("Machines")
        }
    }
}

extension SettingsView {
    /// One machine's page inside a config pane, pushed from the pane's
    /// machine list. Pinned to its machine via `settingsMachineId` so every
    /// sheet keeps talking to that machine.
    @ViewBuilder
    fileprivate func machinePage(for route: MachinePaneRoute) -> some View {
        let machine =
            environment.machines.allMachines.first { $0.id == route.machineId }
            ?? CodevisorMachine.local
        Form {
            switch route.pane {
            case .mcps:
                McpMachinePane(machine: machine)
            case .harnesses:
                HarnessMachinePane(machine: machine)
            case .plugins:
                PluginMachinePane(machine: machine)
            case .skills:
                SkillMachinePane(machine: machine)
            }
        }
        .settingsPaneFormStyle(theme)
        .navigationTitle(machine.name)
        .environment(\.settingsMachineId, machine.id)
        .settingsNavigationToolbar()
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
                UpdatesSettingsEntry()
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
