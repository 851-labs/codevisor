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
        // Attention pings and banner clearing are decided by the app-wide
        // coordinator (edge-triggered, focused chat suppressed); the manager
        // only presents them.
        environment.attentionCoordinator.notificationDelivery = ChatNotificationManager.shared
        // Deep links that open machine-scoped Settings pages ("Manage
        // Harnesses…") resolve the selected machine through this.
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
                AppUpdateCommands(environment: environment)
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
            if !AppPreview.isRunning {
                // Machine readiness belongs to the app runtime, not a window.
                // Settings can be the only restored scene at launch, so waiting
                // until RootView mounts leaves every normal server request gated.
                Task { @MainActor in
                    await runtime.environment.prepareSelectedMachine()
                    // Initialize the terminal runtime up front, in a clean context,
                    // so opening the terminal later can't re-enter its dispatch_once.
                    TerminalRuntime.prewarm()
                }
            }
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
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var selection: SidebarSelection?
    @ClientPreference("sidebar.collapsed", default: false) private var sidebarCollapsed
    @State private var store: SessionStore?
    @State private var preferredProjectId: UUID?
    @State private var requiresInitialNewChatProjectResolution = false
    @State private var quickLook = QuickLookController()
    @State private var panelLayout = AdaptivePanelLayout()

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
                    requiresInitialNewChatProjectResolution = true
                    // Land on the new-workspace page (picker) rather than the
                    // quick-create fast path — the user should name/configure
                    // their first workspace, not get a random one auto-made.
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
        .overlay { DiagnosticsBannerLayer() }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            panelLayout.updateWindowWidth(width)
        }
        // Keep the selected route out of the controller LRU. Read state is
        // acknowledged separately by the transcript viewport.
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
            openNotificationSession(sessionId, serverId: serverId)
        }
        .task { await reconcileSkippedPermissions(environment: environment) }
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
                    // Per-machine truth: skipping permissions disables
                    // Computer Use HERE, never across the fleet.
                    McpFleet.disableLocally(environment.configSync, name: "Computer Use")
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
        // The update center: the one surface for everything updatable,
        // opened from the menu, the sidebar footer, or Settings. Also owns
        // the fleet upkeep cadence.
        .modifier(UpdateCenterPresentation())
        // codevisor://add-machine deeplinks, printed by `codevisor setup` on a
        // remote machine. Extracted into its own modifier: inlining the
        // alerts here pushed this already-large chain past the Swift type
        // checker's budget on release builds.
        .modifier(MachineDeeplinkHandling())
        // codevisor://cloud-auth deeplinks — the browser handoff's fallback
        // path when sign-in ran in the default browser instead of the
        // ASWebAuthenticationSession sheet.
        .modifier(CloudAuthDeeplinkHandling())
        // codevisor://install-plugin deeplinks — the web plugin directory's
        // "Open in Codevisor" button.
        .modifier(PluginInstallDeeplinkHandling())
    }

    private func openNotificationSession(_ sessionId: UUID, serverId: String) {
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
            // No per-machine remount and no machine switcher: the sidebar is
            // the FLEET's. Selection is a routing detail that follows the
            // chat you open (or send), and machines are managed in Settings.
            SidebarView(selection: $selection, store: store)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
                .themedToolbarBackground(theme, role: .sidebar)
        } detail: {
            Group {
                if let store {
                    detail(store, selection: selection)
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
    private func detail(_ store: SessionStore, selection: SidebarSelection?) -> some View {
        switch selection {
        case let .session(serverId, sessionId):
            sessionDetail(store, serverId: serverId, sessionId: sessionId)
        case let .newChat(projectId):
            newChat(store, projectId: projectId)
        case .none:
            newChat(store, projectId: nil)
        }
    }

    @ViewBuilder
    private func sessionDetail(
        _ store: SessionStore,
        serverId: String,
        sessionId: UUID
    ) -> some View {
        if let session = environment.projectList.sessions.first(where: {
            $0.serverId == serverId && $0.id == sessionId
        }),
            let project = environment.projectList.projects.first(where: {
                $0.serverId == serverId && $0.id == session.projectId
            })
        {
            let controller = store.controller(for: session, project: project)
            SessionContainerView(
                session: session,
                project: project,
                store: store,
                controller: controller,
                onFocusedChatChanged: { chatId in
                    self.selection = .session(serverId: serverId, id: chatId)
                }
            )
            .id(
                "\(session.serverId):\((environment.workspaces.workspaceId(forSession: session.id) ?? session.id).uuidString)"
            )
            .onChange(of: session, initial: true) { _, updatedSession in
                store.reconcile(controller, for: updatedSession, project: project)
            }
            .onChange(of: project) { _, updatedProject in
                store.reconcile(controller, for: session, project: updatedProject)
            }
            .onAppear { preferredProjectId = project.id }
        } else {
            ContentUnavailableView(
                "Chat Unavailable",
                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                description: Text("This chat is no longer available on its machine.")
            )
        }
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
            explicitProjectId: projectId,
            requiresInitialProjectResolution: requiresInitialNewChatProjectResolution,
            onInitialProjectResolutionCompleted: {
                requiresInitialNewChatProjectResolution = false
            }
        )
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

/// codevisor://install-plugin deeplink handling: routes to the selected
/// machine's Plugins settings page with the linked repo staged as a pending
/// install. Never auto-installs — the plugins pane opens the standard
/// discover→consent sheet, so the verbatim commands are always shown before
/// anything runs.
private struct PluginInstallDeeplinkHandling: ViewModifier {
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                guard let deeplink = PluginInstallDeeplink.parse(url) else { return }
                SettingsRouter.shared.pendingPluginInstallSource = deeplink.repo
                SettingsRouter.shared.showPlugins()
                openSettings()
            }
    }
}
