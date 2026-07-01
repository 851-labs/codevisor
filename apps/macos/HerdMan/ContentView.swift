import SwiftUI
import HerdManCore

@main
struct HerdManApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            TerminalCommands()
        }

        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}

/// The top-level split view: collapsible sidebar plus the active session or the
/// new-chat page.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection: SidebarSelection?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var store: SessionStore?
    @State private var preferredWorkspaceId: UUID?
    @State private var preparedMachineId: String?

    var body: some View {
        Group {
            if environment.settings.hasCompletedOnboarding {
                mainSplit
            } else {
                OnboardingView { workspace in
                    preferredWorkspaceId = workspace?.id
                    selection = .newChat(workspace?.id)
                }
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
                await environment.appUpdate.checkForUpdates()
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
                    preferredWorkspaceId = nil
                }
                preparedMachineId = machineId
                await environment.prepareSelectedMachine()
                Task {
                    await ConfigPrefetcher(
                        agentService: environment.agentService,
                        cache: environment.configCache
                    ).warmMissing()
                }
                // Initialize the terminal runtime up front, in a clean context,
                // so opening the terminal later can't re-enter its dispatch_once.
                TerminalRuntime.prewarm()
            }
        }
    }

    private var mainSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection, store: store)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            if let store {
                detail(store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            if HerdManAppVariant.isDevelopment {
                // Right of the page title, without the liquid-glass capsule
                // toolbar items get by default.
                ToolbarItem(placement: .principal) {
                    DevelopmentBadge()
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    @ViewBuilder
    private func detail(_ store: SessionStore) -> some View {
        switch selection {
        case let .session(sessionId):
            if let session = environment.workspaceList.sessions.first(where: { $0.id == sessionId }),
               let workspace = environment.workspaceList.workspaces.first(where: { $0.id == session.workspaceId }) {
                SessionContainerView(session: session, workspace: workspace, store: store)
                    .id(session.id)
                    .onAppear { preferredWorkspaceId = workspace.id }
            } else {
                newChat(store, preferred: preferredWorkspaceId)
            }
        case let .newChat(workspaceId):
            newChat(store, preferred: workspaceId ?? preferredWorkspaceId)
        case .none:
            newChat(store, preferred: preferredWorkspaceId)
        }
    }

    private func newChat(_ store: SessionStore, preferred: UUID?) -> some View {
        NewChatView(store: store, selection: $selection, preferredWorkspaceId: preferred)
    }
}

/// Identifies the current sidebar selection.
enum SidebarSelection: Hashable {
    case session(UUID)
    case newChat(UUID?)
}

/// A small blue badge in the window toolbar so development builds are easy to
/// tell apart from the production app at a glance.
private struct DevelopmentBadge: View {
    var body: some View {
        Text("DEV")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.blue))
            .help("Development build of HerdMan")
            .accessibilityLabel("Development build")
    }
}

#Preview("Root") {
    RootView()
        .environment(AppEnvironment.preview())
        .frame(width: 1100, height: 720)
}
