import SwiftUI
import HerdManCore

/// Hosts a session: resolves its cached `SessionController` from the store and
/// shows the session screen.
struct SessionContainerView: View {
    /// Inspector width limits, shared by the column-width modifier and the
    /// persistence clamp below.
    private static let inspectorMinWidth: CGFloat = 220
    private static let inspectorMaxWidth: CGFloat = 480

    let session: ChatSession
    let project: Project
    let store: SessionStore

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var controller: SessionController?
    /// Last user-chosen inspector width. The system only tracks a drag for
    /// the current presentation — the detail subtree's `.id(session.id)`
    /// reset (and app relaunches) would snap back to the hardcoded ideal, so
    /// the measured width is persisted and fed back as `ideal`.
    @AppStorage("inspector.width") private var inspectorWidth: Double = 300
    /// Debounce for width persistence. Writing on every geometry tick would
    /// change `ideal` mid-presentation, which cancels the inspector's
    /// open animation (it snaps) and records transient mid-animation widths.
    @State private var inspectorWidthSave: Task<Void, Never>?

    /// The session's cached scratchpad (cheap dictionary lookup). Holds the
    /// inspector's per-session open state, so it survives the `.id(session.id)`
    /// identity reset in `RootView` and app restarts.
    private var scratchpad: ScratchpadModel {
        store.scratchpad(for: session)
    }

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
            // The inspector toggle lives in the inspector content's toolbar
            // (below): the system pins it at the window's trailing edge and
            // keeps it in the main bar while the inspector is closed, so no
            // separate main-toolbar item is needed here.
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
        // Applied AFTER the toolbar and the manual band so both belong to the
        // chat column only: the inspector then presents as its own full-height
        // trailing column with its own toolbar section (divider through the
        // top bar), instead of sliding underneath a band painted across the
        // whole window.
        .inspector(isPresented: Binding(
            get: { scratchpad.isVisible },
            set: { scratchpad.setVisible($0) }
        )) {
            SessionInspectorView(controller: controller, scratchpad: scratchpad)
                .inspectorColumnWidth(
                    min: Self.inspectorMinWidth,
                    ideal: CGFloat(inspectorWidth),
                    max: Self.inspectorMaxWidth
                )
                // Track divider drags by measuring the content: the width is
                // written back to `inspectorWidth` so the next presentation's
                // `ideal` reopens the inspector at the same size. Persisted
                // only after the size settles (see `inspectorWidthSave`).
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    let clamped = min(max(width, Self.inspectorMinWidth), Self.inspectorMaxWidth)
                    guard abs(clamped - CGFloat(inspectorWidth)) > 0.5 else { return }
                    inspectorWidthSave?.cancel()
                    inspectorWidthSave = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        inspectorWidth = Double(clamped)
                    }
                }
                // Toolbar content inside the inspector lands in the
                // inspector's section of the window toolbar; the spacer pins
                // the toggle to the window's trailing edge.
                .toolbar {
                    Spacer()
                    scratchpadToggleButton
                }
        }
        .focusedSceneValue(\.scratchpadToggle, ScratchpadToggleAction(sessionId: session.id) {
            scratchpad.toggle()
        })
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

    private var scratchpadToggleButton: some View {
        Button {
            scratchpad.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
        }
        .help("Toggle Scratchpad (⌥⌘I)")
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
