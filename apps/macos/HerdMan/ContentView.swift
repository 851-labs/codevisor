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
        .defaultSize(width: 1100, height: 760)
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
                store = SessionStore(
                    agentService: environment.agentService,
                    configCache: environment.configCache,
                    workspaceList: environment.workspaceList,
                    settings: environment.settings
                )
            }
            // Warm the harness config cache in the background so the composer
            // pickers are populated instantly.
            if !AppPreview.isRunning {
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

#Preview("Root") {
    RootView()
        .environment(AppEnvironment.preview())
        .frame(width: 1100, height: 720)
}
