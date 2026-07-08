import SwiftUI
import AppKit
import HerdManCore

@main
struct HerdManApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .themedRoot()
                .environment(environment)
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            AppUpdateCommands(appUpdate: environment.appUpdate)
            FileCommands()
            MachineCommands(machines: environment.machines)
            TerminalCommands()
            ScratchpadCommands()
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
    @State private var selection: SidebarSelection?
    // Seeded from UserDefaults so a collapsed sidebar survives relaunch;
    // written back in `mainSplit`'s onChange. `NavigationSplitViewVisibility`
    // isn't RawRepresentable, so it can't live in @AppStorage directly.
    @State private var columnVisibility: NavigationSplitViewVisibility =
        UserDefaults.standard.bool(forKey: "sidebar.collapsed") ? .detailOnly : .all
    @State private var store: SessionStore?
    @State private var preferredProjectId: UUID?
    @State private var preparedMachineId: String?
    @State private var lightbox = LightboxController()

    var body: some View {
        Group {
            if environment.settings.hasCompletedOnboarding {
                mainSplit
            } else {
                OnboardingView { project in
                    preferredProjectId = project?.id
                    selection = .newChat(project?.id)
                }
            }
        }
        .environment(\.lightbox, lightbox)
        // Locks the composer's submit action while an update installs (the
        // app or selected server is about to restart).
        .environment(\.isAppUpdateInProgress, environment.isUpdateInProgress)
        // Window-level so the viewer covers the sidebar too, matching a true
        // full-window lightbox rather than a session-column sheet. The window
        // toolbar (session title, sidebar toggle) draws above SwiftUI
        // overlays, so it is hidden while the viewer is up.
        .toolbar(lightbox.item == nil ? .automatic : .hidden, for: .windowToolbar)
        .overlay {
            if let item = lightbox.item {
                AttachmentLightbox(item: item, controller: lightbox)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.15), value: lightbox.item)
        // Track which session is on screen so finished turns only badge the
        // sidebar rows of chats the user hasn't opened.
        .onChange(of: selection) { _, newValue in
            guard let store else { return }
            if case let .session(sessionId) = newValue {
                store.markOpened(sessionId)
            } else {
                store.clearOpenSession()
            }
        }
        .task {
            if store == nil {
                store = SessionStore(environment: environment)
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

    private var mainSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection, store: store)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
                .themedToolbarBackground(theme, surface: theme.sidebarBackground)
                #if DEBUG
                // Dev builds show an ant in the sidebar toolbar — the classic
                // debug marker — so they're recognizable at a glance.
                .toolbar {
                    ToolbarItem {
                        Button {} label: {
                            Image(systemName: "ant")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .help("Development build")
                    }
                }
                #endif
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
        .onChange(of: columnVisibility) { _, newValue in
            UserDefaults.standard.set(newValue == .detailOnly, forKey: "sidebar.collapsed")
        }
    }

    @ViewBuilder
    private func detail(_ store: SessionStore) -> some View {
        switch selection {
        case let .session(sessionId):
            if let session = environment.projectList.sessions.first(where: { $0.id == sessionId }),
               let project = environment.projectList.projects.first(where: { $0.id == session.projectId }) {
                SessionContainerView(session: session, project: project, store: store)
                    .id(session.id)
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
    }
}

/// Identifies the current sidebar selection.
enum SidebarSelection: Hashable {
    case session(UUID)
    case newChat(UUID?)
}

#Preview("Root") {
    RootView()
        .environment(AppEnvironment.preview())
        .frame(width: 1100, height: 720)
}
