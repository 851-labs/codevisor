import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import QuickLook
import CodevisorUI

@main
struct CodevisorApp: App {
    @State private var environment: AppEnvironment?
    @State private var serverAgent: MacServerAgentController
    @State private var sparkleUpdater: SparkleUpdateController?
    @State private var startupError: String?
    @State private var startupInProgress = false

    init() {
        let serverAgent = MacServerAgentController()
        _environment = State(initialValue: nil)
        _serverAgent = State(initialValue: serverAgent)
        _sparkleUpdater = State(initialValue: nil)
        _startupError = State(initialValue: nil)
    }

    @MainActor
    private static func makeRuntime(
        serverAgent: MacServerAgentController,
        storage: ClientStorage
    ) -> (environment: AppEnvironment, updater: SparkleUpdateController?) {
        let environment = AppEnvironment.live(storage: storage)
        if !CodevisorAppVariant.isDevelopment {
            environment.localServer?.configureManagedService(serverAgent.managedService)
        }
        let sparkleUpdater =
            CodevisorAppVariant.enablesSparkleUpdater
            ? SparkleUpdateController(
                model: environment.appUpdate,
                localServer: environment.localServer,
                serverAgent: serverAgent
            )
            : nil
        if !CodevisorAppVariant.isDevelopment && !AppPreview.isRunning {
            // Keep the bundled CLI (`codevisor` etc.) linked into
            // ~/.local/bin: DMG drag-installs run no installer script, so
            // launch is the only chance to put the CLI on PATH; install.sh
            // and the Homebrew cask create the same links up front.
            Task.detached(priority: .utility) {
                CommandLineTools.ensureInstalled()
            }
        }
        if !AppPreview.isRunning {
            let probes = ComputerUsePermissionProbes.live
            let allGranted = probes.isAccessibilityGranted() && probes.isScreenRecordingGranted()
            let needsReview = computerUsePermissionsGateNeeded(
                hasCompletedOnboarding: environment.settings.hasCompletedOnboarding,
                permissionsReviewedVersion: environment.settings.permissionsReviewedVersion,
                setupSkipped: environment.settings.permissionsSetupSkipped,
                reviewInProgress: environment.settings.permissionsReviewInProgress,
                currentVersion: AppUpdateModel.bundleVersion(),
                allGranted: allGranted
            )
            environment.requiresPermissionsReview = needsReview
            if needsReview {
                // Survives the restart that granting Screen Recording asks
                // for; the dialog's own buttons clear it.
                environment.settings.setPermissionsReviewInProgress(true)
            } else if allGranted,
                environment.settings.permissionsReviewedVersion
                    != AppUpdateModel.bundleVersion()
            {
                // Everything already granted and no review open: count this
                // version reviewed so a later revoke does not re-gate it.
                environment.settings.setPermissionsReviewedVersion(AppUpdateModel.bundleVersion())
            }
        }
        AnalyticsClient.shared.configureFromMainBundle(enabled: environment.settings.shareAnalytics)
        AnalyticsClient.shared.captureAppOpenedOnce()
        DiagnosticsClient.shared.configureFromMainBundle(enabled: environment.settings.shareCrashReports)
        ChatNotificationManager.shared.configure(settings: environment.settings)
        // Deep links that open machine-scoped Settings pages ("Manage
        // Harnesses…") resolve the selected machine through this.
        SettingsRouter.shared.selectedMachineIdProvider = { [weak environment] in
            environment?.machines.selectedMachineId
        }
        return (environment, sparkleUpdater)
    }

    var body: some Scene {
        WindowGroup {
            if let environment {
                RootView()
                    .frame(minWidth: 480, minHeight: 600)
                    .themedRoot()
                    .modifier(DebugMetricsOverlayModifier())
                    .environment(environment)
                    // Deeplinks (codevisor://add-machine) should land in the
                    // window that's already open; without this, macOS spawns a
                    // fresh window scene for every external URL event.
                    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            } else if let startupError {
                ClientDataStartupFailureView(
                    message: startupError,
                    retry: retryStartup,
                    showDataFolder: {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            CodevisorAppVariant.applicationSupportURL()
                        ])
                    }
                )
                .frame(minWidth: 480, minHeight: 600)
            } else {
                ClientDataStartupView()
                    .frame(minWidth: 480, minHeight: 600)
                    .task { await startRuntimeIfNeeded() }
            }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        // Keep the native zoom target stable while responsive side panels
        // mount and unmount as the window crosses their width thresholds.
        // AppKit still owns saving and restoring the user's previous frame.
        .windowIdealSize(.maximum)
        .commands {
            if let environment {
                AppUpdateCommands(appUpdate: environment.appUpdate)
                FileCommands()
                MachineCommands(machines: environment.machines)
                TerminalCommands()
                WorkspaceLayoutCommands()
                DebugOverlayCommands()
            }
        }

        Settings {
            if let environment {
                SettingsView()
                    .themedRoot()
                    .environment(environment)
            } else if let startupError {
                ClientDataStartupFailureView(
                    message: startupError,
                    retry: retryStartup,
                    showDataFolder: {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            CodevisorAppVariant.applicationSupportURL()
                        ])
                    }
                )
            } else {
                ClientDataStartupView()
                    .task { await startRuntimeIfNeeded() }
            }
        }
    }

    private func retryStartup() {
        startupError = nil
        Task { await startRuntimeIfNeeded() }
    }

    @MainActor
    private func startRuntimeIfNeeded() async {
        guard environment == nil, !startupInProgress else { return }
        startupInProgress = true
        defer { startupInProgress = false }
        do {
            let storage = try await ClientStorageBootstrap.openAsync(
                directory: CodevisorAppVariant.applicationSupportURL(),
                credentials: KeychainMachineCredentialStore.shared
            )
            let runtime = Self.makeRuntime(serverAgent: serverAgent, storage: storage)
            environment = runtime.environment
            sparkleUpdater = runtime.updater
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }
}

private struct ClientDataStartupFailureView: View {
    let message: String
    let retry: () -> Void
    let showDataFolder: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Codevisor Couldn't Open Its Data", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("The app stopped before loading or syncing so your existing data remains intact.\n\n\(message)")
        } actions: {
            HStack {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                Button("Show Data Folder", action: showDataFolder)
            }
        }
        .padding(32)
    }
}

/// The top-level split view: collapsible sidebar plus the active session or the
/// new-chat page.
struct RootView: View {
    @Environment(AppEnvironment.self) var environment
    @Environment(\.theme) var theme
    @Environment(\.controlActiveState) private var controlActiveState
    @State var selection: SidebarSelection?
    @ClientPreference("sidebar.collapsed", default: false) private var sidebarCollapsed
    @State private var store: SessionStore?
    @State private var preferredProjectId: UUID?
    @State private var preparedMachineId: String?
    @State private var quickLook = QuickLookController()
    @State private var panelLayout = AdaptivePanelLayout()
    /// Navigation selection is immediate, but the last presentable detail
    /// remains above a different workspace until its routed transcript has
    /// committed authoritative geometry.
    @State var detailPresentation: StagedPresentationGate<DetailPresentationRoute> = {
        var gate = StagedPresentationGate<DetailPresentationRoute>()
        let route = DetailPresentationRoute(selection: nil, surfaceId: .bootstrap)
        let generation = gate.request(route)
        _ = gate.commit(route, generation: generation)
        return gate
    }()

    struct DetailPresentationRoute: Hashable {
        let selection: SidebarSelection?
        let surfaceId: DetailSurfaceId
    }

    enum DetailSurfaceId: Hashable {
        case bootstrap
        case blocked(String)
        case workspace(serverId: String, workspaceId: UUID)
        case newChat(String)
    }

    var body: some View {
        Group {
            if environment.settings.hasCompletedOnboarding {
                mainSplit
            } else {
                // Resumes where a mid-flow relaunch left off (granting Screen
                // Recording asks for one) instead of restarting the flow.
                OnboardingView(
                    initialStep: OnboardingView.resumeStep(from: environment.settings)
                ) { project in
                    preferredProjectId = project?.id
                    // Land on the new-workspace page (picker) rather than the
                    // quick-create fast path — the user should name/configure
                    // their first workspace, not get a random one auto-made.
                    selection = .newChat(nil)
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
        .overlay { DiagnosticsBannerLayer() }
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
        // A server refresh can invalidate the route from another device.
        // Apply the shared sibling-or-dismiss policy even though the archived
        // session remains in the local model for the archive section.
        .onChange(of: selectedSessionDisposition, initial: true) { _, disposition in
            applySelectedSessionDisposition(disposition)
        }
        .onChange(of: controlActiveState, initial: true) { _, state in
            store?.setWindowFocused(state == .key)
        }
        .onReceive(NotificationCenter.default.publisher(for: .codevisorOpenChatNotification)) { note in
            guard let sessionIdString = note.userInfo?["sessionId"] as? String,
                let sessionId = UUID(uuidString: sessionIdString),
                let serverId = note.userInfo?["serverId"] as? String
            else { return }
            Task { await openNotificationSession(sessionId, serverId: serverId) }
        }
        .task { await reconcileSkippedPermissions() }
        // An update arrived and the Computer Use permissions are not set up:
        // ask once per version, as a dialog over the app rather than a
        // takeover. An overlay rather than a sheet — see the gate view; a
        // modal sheet would block the "Quit & Reopen" that granting Screen
        // Recording ends in.
        .overlay {
            if environment.requiresPermissionsReview {
                ComputerUsePermissionsGateView {
                    environment.settings.setPermissionsReviewedVersion(
                        AppUpdateModel.bundleVersion()
                    )
                    environment.settings.setPermissionsSetupSkipped(false)
                    environment.settings.setPermissionsReviewInProgress(false)
                    environment.requiresPermissionsReview = false
                } onSkip: {
                    // Computer Use turns off so nothing half-works; the
                    // Computer Use toggle in Settings re-enters setup.
                    environment.settings.setPermissionsSetupSkipped(true)
                    environment.settings.setPermissionsReviewInProgress(false)
                    Task {
                        try? await environment.serverClient.setMcpServerEnabled(
                            id: "computer",
                            enabled: false
                        )
                    }
                    environment.requiresPermissionsReview = false
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: environment.requiresPermissionsReview)
        .task {
            if store == nil {
                store = SessionStore(environment: environment)
                store?.setWindowFocused(controlActiveState == .key)
            }
            if !AppPreview.isRunning {
                // A remote client updated this machine's server: the bundled
                // server hands the update back here. Sparkle installs the
                // signed app update and replaces app + bundled server
                // together — unattended, because the person who asked is at
                // ANOTHER machine's screen and nobody here could accept a
                // prompt.
                environment.localServer?.onUpdateRequested = { [environment] in
                    Task { @MainActor in
                        await environment.appUpdate.installUpdateUnattended()
                    }
                }
                // Restore the cloud account session (or adopt the dev cloud
                // token) in the background; nothing at boot depends on it.
                await environment.cloud.bootstrap()
            }
        }
        // codevisor://add-machine deeplinks, printed by `codevisor setup` on a
        // remote machine. Extracted into its own modifier: inlining the
        // alerts here pushed this already-large chain past the Swift type
        // checker's budget on release builds.
        .modifier(MachineDeeplinkHandling())
        // codevisor://cloud-auth deeplinks — the browser handoff's fallback
        // path when sign-in ran in the default browser instead of the
        // ASWebAuthenticationSession sheet.
        .modifier(CloudAuthDeeplinkHandling())
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
        .task(id: environment.machines.selectedMachineId) {
            guard !AppPreview.isRunning else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5 * 60))
                } catch {
                    return
                }
                await environment.machines.refreshSelectedServerUpdate()
            }
        }
    }

    /// Heals a half-applied "Set Up Later": the skip choice persists locally
    /// but the Computer Use disable is a server call that can be lost (the
    /// app may quit before it lands). Skipped + permissions missing means
    /// Computer Use must be off; skipped + permissions granted means the
    /// skip is obsolete.
    private func reconcileSkippedPermissions() async {
        guard !AppPreview.isRunning, environment.settings.permissionsSetupSkipped else { return }
        let probes = ComputerUsePermissionProbes.live
        if probes.isAccessibilityGranted() && probes.isScreenRecordingGranted() {
            environment.settings.setPermissionsSetupSkipped(false)
            return
        }
        for attempt in 0..<30 {
            if let servers = try? await environment.serverClient.listMcpServers(),
                let computer = servers.first(where: { $0.kind == "computerUse" })
            {
                if computer.enabled {
                    _ = try? await environment.serverClient.setMcpServerEnabled(
                        id: "computer",
                        enabled: false
                    )
                }
                return
            }
            if attempt < 29 {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func openNotificationSession(_ sessionId: UUID, serverId: String) async {
        if environment.machines.selectedMachineId != serverId {
            environment.machines.selectMachine(serverId)
            await environment.prepareSelectedMachine()
        }
        guard
            let session = environment.projectList.sessions.first(where: {
                $0.serverId == serverId && $0.id == sessionId
            })
        else { return }
        preferredProjectId = session.projectId
        selection = .session(serverId: serverId, id: sessionId)
    }

    /// Shared Core policy keeps both native navigation surfaces aligned when
    /// an event archives, unarchives, moves, or removes the current chat.
    private var selectedSessionDisposition: WorkspaceRouteDisposition {
        guard case let .session(serverId, sessionId) = selection else { return .keep }
        _ = environment.workspaceSync.revision
        return environment.workspaceSync.routeDisposition(
            sessionId: sessionId,
            serverId: serverId
        )
    }

    private func applySelectedSessionDisposition(_ disposition: WorkspaceRouteDisposition) {
        guard case let .session(serverId, sessionId) = selection else { return }
        switch disposition {
        case .keep:
            break
        case let .selectSession(replacementId):
            guard replacementId != sessionId else { return }
            selection = .session(serverId: serverId, id: replacementId)
        case .dismiss:
            preferredProjectId = nil
            selection = .newChat(nil)
        }
    }

    /// The top-level split: the NATIVE NavigationSplitView + NSToolbar pair
    /// (Finder's model) — sidebar tracking, the collapse animation, window
    /// dragging, and fullscreen are all system behavior. The pane tab bar is
    /// ordinary content BELOW the toolbar (see SessionContainerView).
    private var mainSplit: some View {
        NavigationSplitView(columnVisibility: sidebarColumnVisibility) {
            SidebarView(selection: $selection, store: store)
                .id(environment.machines.selectedMachineId)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
                .themedToolbarBackground(theme, role: .sidebar)
                .toolbar {
                    ToolbarItem {
                        MachinePickerToolbarMenu()
                    }
                }
        } detail: {
            Group {
                if let store {
                    stagedDetail(store)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .themedToolbarBackground(theme, role: .content)
            // The pane tab bar draws its own bottom divider; a system hairline
            // above it would box the tab strip in between two rules.
            .hidesTitlebarSeparator()
        }
        .overlay {
            AdaptiveDrawerLayer(
                isPresented: !panelLayout.docksSidebar && panelLayout.activeDrawer == .leading,
                edge: .leading,
                width: min(270, panelLayout.windowWidth - 16)
            ) {
                SidebarView(selection: $selection, store: store, publishesSceneActions: false)
                    .id(environment.machines.selectedMachineId)
                    .themedSurface(.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    func detail(_ store: SessionStore, selection: SidebarSelection?) -> some View {
        if blocksSelectedServerContent {
            let machine = environment.machines.selectedMachine
            ServerAvailabilityView(
                machineId: machine.id,
                availability: environment.machines.selectedServerAvailability,
                machineName: machine.name,
                isLocal: machine.isLocal,
                dataUpgradeProgress: machine.isLocal
                    ? environment.localServer?.dataUpgradeProgress
                    : nil,
                appUpdateInProgress: environment.appUpdate.isUpdating
            ) {
                Task { await environment.machines.retrySelectedMachine() }
            }
            .reportsPresentationReadyAfterLayout(.laidOut)
        } else {
            switch selection {
            case let .session(serverId, sessionId):
                if serverId == environment.machines.selectedMachineId,
                    let session = environment.projectList.sessions.first(where: {
                        $0.serverId == serverId && $0.id == sessionId
                    }),
                    let project = environment.projectList.projects.first(where: {
                        $0.serverId == serverId && $0.id == session.projectId
                    })
                {
                    let controller = store.controller(for: session, project: project)
                    // Identity is the WORKSPACE, not the chat: clicking a
                    // sibling chat swaps only the routed session (the container
                    // selects + focuses it) instead of tearing down and
                    // rebuilding the same panes — which also cancelled the
                    // shared controllers' in-flight history loads. Sessions
                    // without a workspace yet (first open backfills one) fall
                    // back to session identity.
                    SessionContainerView(
                        session: session,
                        project: project,
                        store: store,
                        controller: controller,
                        // Focus moved to a sibling chat: the sidebar selection
                        // follows (same workspace identity — no remount, the
                        // container just re-routes).
                        onFocusedChatChanged: { chatId in
                            self.selection = .session(serverId: serverId, id: chatId)
                        }
                    )
                    .id(
                        "\(session.serverId):\((environment.workspaces.workspaceId(forSession: session.id) ?? session.id).uuidString)"
                    )
                    .onAppear { preferredProjectId = project.id }
                } else {
                    // The routed session can't be resolved (machine switch,
                    // deletion): fall back to the new-chat page.
                    newChat(store, projectId: nil)
                }
            case let .newChat(projectId):
                newChat(store, projectId: projectId)
            case .none:
                newChat(store, projectId: nil)
            }
        }
    }

    var blocksSelectedServerContent: Bool {
        if environment.appUpdate.isUpdating { return true }
        if environment.machines.selectedMachine.isLocal,
            let progress = environment.localServer?.dataUpgradeProgress,
            progress.state == "running" || progress.state == "failed"
        {
            return true
        }
        if case .ready = environment.machines.selectedServerAvailability {
            return false
        }
        return true
    }

    /// The standalone new-chat page. Creates NOTHING until the first message
    /// is sent — sending resolves the picked directory (project folder or a
    /// fresh worktree) and materializes the workspace around the started
    /// chat. A sidebar per-project button preselects that project.
    private func newChat(_ store: SessionStore, projectId: UUID?) -> some View {
        NewChatView(
            store: store,
            selection: $selection,
            preferredProjectId: projectId,
            explicitProjectId: projectId
        )
        .id(environment.machines.selectedMachineId)
        .reportsPresentationReadyAfterLayout(.laidOut)
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

/// codevisor://cloud-auth?ott=… deeplink handling: completes a cloud sign-in
/// that came back through the default browser (the in-app
/// ASWebAuthenticationSession path never leaves the app) and routes to the
/// Account settings tab so the result is visible.
private struct CloudAuthDeeplinkHandling: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            // No confirmation gate: the one-time token proves a sign-in this
            // user just performed, is single-use, and expires in minutes.
            .onOpenURL { url in
                guard let deeplink = CloudAuthDeeplink.parse(url) else { return }
                Task { await environment.cloud.completeSignIn(ott: deeplink.ott) }
                SettingsRouter.shared.showMachines()
                openSettings()
            }
    }
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
            SettingsRouter.shared.showMachines()
            openSettings()
        } catch {
            deeplinkError = String(describing: error)
        }
    }
}
