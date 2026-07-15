import SwiftUI
import CodevisorCore
import QuickLook

@main
struct CodevisorApp: App {
    @State private var environment: AppEnvironment

    init() {
        let environment = AppEnvironment.live()
        _environment = State(initialValue: environment)
        ChatNotificationManager.shared.configure(settings: environment.settings)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 480, minHeight: 600)
                .themedRoot()
                .modifier(DebugMetricsOverlayModifier())
                .environment(environment)
                // Deeplinks (codevisor://add-machine) should land in the
                // window that's already open; without this, macOS spawns a
                // fresh window scene for every external URL event.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            AppUpdateCommands(appUpdate: environment.appUpdate)
            FileCommands()
            MachineCommands(machines: environment.machines)
            TerminalCommands()
            ScratchpadCommands()
            DebugOverlayCommands()
            // Provides the Format menu (⌘B/⌘I etc.) for the scratchpad's
            // rich TextEditor; only acts on focused rich-text views, so the
            // plain-text composer is unaffected.
            TextFormattingCommands()
        }

        Settings {
            SettingsView()
                .themedRoot()
                .environment(environment)
        }
    }
}

/// The top-level split view: collapsible sidebar plus the active session or the
/// new-chat page.
struct RootView: View {
    private static let appUpdateCheckInterval: Duration = .seconds(300)

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var selection: SidebarSelection?
    @AppStorage("sidebar.collapsed") private var sidebarCollapsed = false
    @State private var store: SessionStore?
    @State private var preferredProjectId: UUID?
    @State private var preparedMachineId: String?
    @State private var quickLook = QuickLookController()
    @State private var panelLayout = AdaptivePanelLayout()

    var body: some View {
        Group {
            if let progress = environment.localServer?.dataUpgradeProgress,
               progress.state == "running" || progress.state == "failed" {
                DataUpgradeView(progress: progress) {
                    Task { await environment.localServer?.ensureRunning() }
                }
            } else if environment.settings.hasCompletedOnboarding {
                mainSplit
            } else {
                OnboardingView { project in
                    preferredProjectId = project?.id
                    selection = .newChat(project?.id)
                }
            }
        }
        .environment(panelLayout)
        .environment(\.quickLook, quickLook)
        .quickLookPreview(
            Binding(
                get: { quickLook.previewURL },
                set: { quickLook.updatePreviewURL($0) }
            )
        )
        // Locks the composer's submit action while an update installs (the
        // app or selected server is about to restart).
        .environment(\.isAppUpdateInProgress, environment.isUpdateInProgress)
        // App-level fallback surface for errors with no natural home in the
        // UI (background sync, persistence).
        .overlay { ErrorBannerLayer() }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            panelLayout.updateWindowWidth(width)
        }
        // Track which session is on screen so finished turns only badge the
        // sidebar rows of chats the user hasn't opened.
        .onChange(of: selection) { _, newValue in
            panelLayout.dismissDrawer(.leading)
            guard let store else { return }
            if case let .session(serverId, sessionId) = newValue {
                store.markOpened(sessionId, serverId: serverId)
            } else {
                store.clearOpenSession()
            }
        }
        .onChange(of: controlActiveState, initial: true) { _, state in
            store?.setWindowFocused(state == .key)
        }
        .onReceive(NotificationCenter.default.publisher(for: .codevisorOpenChatNotification)) { note in
            guard let sessionIdString = note.userInfo?["sessionId"] as? String,
                  let sessionId = UUID(uuidString: sessionIdString),
                  let serverId = note.userInfo?["serverId"] as? String else { return }
            Task { await openNotificationSession(sessionId, serverId: serverId) }
        }
        .task {
            if store == nil {
                store = SessionStore(environment: environment)
                store?.setWindowFocused(controlActiveState == .key)
            }
            if !AppPreview.isRunning {
                environment.appUpdate.installHandler = { [environment] release in
                    try await AppUpdateInstaller(environment: environment).install(release)
                }
                // A remote client updated this machine's server: the bundled
                // server can't swap the .app bundle it lives inside, so it
                // hands the update back here. Run the full app update (swap
                // bundle + relaunch), which brings a fresh bundled server. On
                // failure installUpdate returns; restart the old server so the
                // machine isn't left without one.
                environment.localServer?.onUpdateRequested = { [environment] in
                    Task { @MainActor in
                        await environment.appUpdate.checkForUpdates()
                        await environment.appUpdate.installUpdate()
                        await environment.localServer?.ensureRunning()
                    }
                }
                await runAppUpdateChecks()
            }
        }
        // codevisor://add-machine deeplinks, printed by `codevisor setup` on a
        // remote machine. Extracted into its own modifier: inlining the
        // alerts here pushed this already-large chain past the Swift type
        // checker's budget on release builds.
        .modifier(MachineDeeplinkHandling())
        .task(id: environment.machines.selectedMachineId) {
            // Warm the harness config cache in the background so the composer
            // pickers are populated instantly.
            if !AppPreview.isRunning {
                // Machine switches (from the picker or Settings) leave the old
                // machine's session behind. This must happen synchronously,
                // before any await: resetting after `prepare` finishes would
                // race with (and clobber) a session the user clicked meanwhile.
                let machineId = environment.machines.selectedMachineId
                if let preparedMachineId, preparedMachineId != machineId {
                    selection = .newChat(nil)
                    preferredProjectId = nil
                }
                preparedMachineId = machineId
                await environment.prepareSelectedMachine()
                // Initialize the terminal runtime up front, in a clean context,
                // so opening the terminal later can't re-enter its dispatch_once.
                TerminalRuntime.prewarm()
            }
        }
    }

    private func runAppUpdateChecks() async {
        await environment.appUpdate.checkForUpdates()
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.appUpdateCheckInterval)
            guard !Task.isCancelled else { return }
            await environment.appUpdate.checkForUpdatesInBackground()
        }
    }

    private func openNotificationSession(_ sessionId: UUID, serverId: String) async {
        if environment.machines.selectedMachineId != serverId {
            environment.machines.selectMachine(serverId)
            await environment.prepareSelectedMachine()
        }
        guard let session = environment.projectList.sessions.first(where: {
            $0.serverId == serverId && $0.id == sessionId
        }) else { return }
        preferredProjectId = session.projectId
        selection = .session(serverId: serverId, id: sessionId)
    }

    private var mainSplit: some View {
        NavigationSplitView(columnVisibility: sidebarColumnVisibility) {
            SidebarView(selection: $selection, store: store)
                .id(environment.machines.selectedMachineId)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
                .themedToolbarBackground(theme, surface: theme.sidebarBackground)
                .toolbar {
                    ToolbarItem {
                        MachinePickerToolbarMenu()
                    }
                }
        } detail: {
            Group {
                if let store {
                    detail(store)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .themedToolbarBackground(theme, surface: theme.windowBackground)
        }
        .overlay {
            AdaptiveDrawerLayer(
                isPresented: !panelLayout.docksSidebar && panelLayout.activeDrawer == .leading,
                edge: .leading,
                width: min(270, panelLayout.windowWidth - 16)
            ) {
                SidebarView(selection: $selection, store: store, publishesSceneActions: false)
                    .id(environment.machines.selectedMachineId)
                    .background(theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
            }
        }
    }

    /// At compact widths the system sidebar remains collapsed and its normal
    /// toggle opens our transient drawer instead. Automatic collapse doesn't
    /// touch the persisted `sidebarCollapsed` preference.
    private var sidebarColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                panelLayout.docksSidebar && !sidebarCollapsed ? .all : .detailOnly
            },
            set: { visibility in
                if panelLayout.docksSidebar {
                    sidebarCollapsed = visibility == .detailOnly
                } else if visibility != .detailOnly {
                    panelLayout.toggleDrawer(.leading)
                }
            }
        )
    }

    @ViewBuilder
    private func detail(_ store: SessionStore) -> some View {
        switch selection {
        case let .session(serverId, sessionId):
            if serverId == environment.machines.selectedMachineId,
               let session = environment.projectList.sessions.first(where: {
                   $0.serverId == serverId && $0.id == sessionId
               }),
               let project = environment.projectList.projects.first(where: {
                   $0.serverId == serverId && $0.id == session.projectId
               }) {
                SessionContainerView(session: session, project: project, store: store)
                    .id("\(session.serverId):\(session.id.uuidString)")
                    .onAppear { preferredProjectId = project.id }
            } else {
                newChat(store, preferred: preferredProjectId)
            }
        case let .newChat(projectId):
            newChat(store, preferred: projectId ?? preferredProjectId, explicit: projectId)
        case .none:
            newChat(store, preferred: preferredProjectId)
        }
    }

    private func newChat(_ store: SessionStore, preferred: UUID?, explicit: UUID? = nil) -> some View {
        NewChatView(
            store: store,
            selection: $selection,
            preferredProjectId: preferred,
            explicitProjectId: explicit
        )
        .id(environment.machines.selectedMachineId)
    }
}

/// Identifies the current sidebar selection.
enum SidebarSelection: Hashable {
    case session(serverId: String, id: UUID)
    case newChat(UUID?)
}

#Preview("Root") {
    RootView()
        .environment(AppEnvironment.preview())
        .frame(width: 1100, height: 720)
}

/// codevisor://add-machine deeplink handling: parse, confirm, add, and route
/// to the Machines settings tab. Lives in its own modifier so RootView's
/// modifier chain stays within the Swift type checker's budget.
private struct MachineDeeplinkHandling: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings
    @State private var pendingDeeplink: MachineDeeplink?
    @State private var deeplinkError: String?

    func body(content: Content) -> some View {
        content
            // Never auto-add: the token grants full agent access, so an
            // explicit confirmation always sits between the link and the
            // machine list.
            .onOpenURL { url in
                guard let deeplink = MachineDeeplink.parse(url) else { return }
                pendingDeeplink = deeplink
            }
            .alert(
                "Add Remote Machine?",
                isPresented: confirmPresented,
                presenting: pendingDeeplink
            ) { deeplink in
                Button("Add \(deeplink.displayName)") { confirm(deeplink) }
                Button("Cancel", role: .cancel) { pendingDeeplink = nil }
            } message: { deeplink in
                Text(
                    """
                    “\(deeplink.displayName)” (\(deeplink.hostWithPort)) will be added to your \
                    machines. Codevisor will be able to run agents and read files on it.
                    """
                )
            }
            .alert(
                "Couldn't Add Machine",
                isPresented: errorPresented,
                presenting: deeplinkError
            ) { _ in
                Button("OK", role: .cancel) { deeplinkError = nil }
            } message: { error in
                Text(error)
            }
    }

    private var confirmPresented: Binding<Bool> {
        Binding(
            get: { pendingDeeplink != nil },
            set: { if !$0 { pendingDeeplink = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { deeplinkError != nil },
            set: { if !$0 { deeplinkError = nil } }
        )
    }

    /// Adds (or, for an existing address, re-tokens and selects) the machine
    /// from a confirmed deeplink, then lands the user on the Machines settings
    /// tab so the new connection's status is visible.
    private func confirm(_ deeplink: MachineDeeplink) {
        defer { pendingDeeplink = nil }
        do {
            _ = try environment.machines.addRemote(
                host: deeplink.hostWithPort,
                name: deeplink.name,
                token: deeplink.token
            )
            SettingsRouter.shared.selectedTab = .machines
            openSettings()
        } catch {
            deeplinkError = String(describing: error)
        }
    }
}
