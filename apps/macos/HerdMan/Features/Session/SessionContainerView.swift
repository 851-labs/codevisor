import SwiftUI
import HerdManCore

/// Hosts a session: resolves its cached `SessionController` from the store and
/// shows the session screen.
struct SessionContainerView: View {
    let session: ChatSession
    let project: Project
    let store: SessionStore

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var controller: SessionController?

    var body: some View {
        Group {
            if let controller {
                SessionScreen(controller: controller, paneGroup: store.paneGroup(for: session, project: project))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The window keeps the plain title (Window menu, Mission Control), but
        // the toolbar's default title item is replaced with a custom leading
        // title + branch-diff pair — a toolbar item added next to the default
        // title would land in the middle of the top bar, not at the end of the
        // session name.
        .navigationTitle(session.title)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let diffDirectory {
                        BranchDiffBadge(directory: diffDirectory)
                    }
                }
                // Matches the system toolbar title's leading inset (measured
                // against the default title this item replaces).
                .padding(.leading, 12)
            }
            // It's a title, not a control: no glass capsule behind it.
            .sharedBackgroundVisibility(.hidden)
        }
        // Removing the default title item (above) also drops the toolbar's
        // backing on macOS 26, leaving the top bar fully transparent over
        // scrolled chat content. Restoring it with
        // `.toolbarBackgroundVisibility(.visible)` only takes effect when the
        // binary is linked against the macOS 27 SDK — release builds come from
        // the macOS 26 SDK (macos-26 CI runners), where the top bar stayed
        // transparent except for the hover glass. Paint the band manually
        // instead (same overlay pattern as `themedToolbarBackground`) with the
        // system bar material so it renders identically under both SDKs.
        // Custom themes keep it hidden because ThemedRoot's
        // `themedToolbarBackground` paints its own opaque band instead.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .overlay {
            if theme.isSystem {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(.bar)
                        .frame(height: proxy.safeAreaInsets.top)
                        .offset(y: -proxy.safeAreaInsets.top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .task(id: session.id) {
            store.markOpened(session.id)
            let controller = store.controller(for: session, project: project)
            self.controller = controller
            if !controller.isPrepared && !controller.isConnected {
                await controller.prepare()
            }
            // Eagerly connect so the model/reasoning pickers are available for
            // follow-ups (no-op if already connected, e.g. the new-chat handoff).
            if !AppPreview.isRunning {
                await controller.connectIfNeeded()
            }
        }
    }

    /// The directory whose git state the top-bar diff reflects: the session's
    /// cwd (worktree or project folder). Local machines only — a remote
    /// session's paths don't exist on this Mac.
    private var diffDirectory: URL? {
        guard (environment.machines.machine(for: session.serverId) ?? .local).isLocal else { return nil }
        if let cwd = session.cwd { return URL(fileURLWithPath: cwd) }
        return project.folderURL
    }
}
