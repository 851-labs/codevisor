import SwiftUI
import CodevisorCore

/// Hosts a session: resolves its cached `SessionController` from the store and
/// shows the session screen.
struct SessionContainerView: View {
    /// The title is drawn in the top-bar overlay instead of as an `NSToolbar`
    /// item. In compact windows it starts after the traffic lights, machine
    /// picker, and leading-sidebar toggle; a docked sidebar owns that chrome.
    private static let compactToolbarTitleLeadingInset: CGFloat = 188
    private static let dockedToolbarTitleLeadingInset: CGFloat = 12
    private static let toolbarTitleTrailingInset: CGFloat = 60

    /// Inspector width limits, shared by the column-width modifier and the
    /// persistence clamp below.
    private static let inspectorMinWidth: CGFloat = 220
    private static let inspectorMaxWidth: CGFloat = 480

    let session: ChatSession
    let project: Project
    let store: SessionStore

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(AdaptivePanelLayout.self) private var panelLayout
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
        // its default toolbar title is removed. The visible title is rendered
        // by `sessionToolbarTitleOverlay` below: `NSToolbar` animates custom
        // items toward its overflow menu while resizing, whereas the overlay
        // behaves like an ordinary constrained row and truncates directly.
        .navigationTitle(session.title)
        .toolbar(removing: .title)
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
                        // This manually painted band replaces the hidden
                        // toolbar background, so explicitly restore the native
                        // window drag/zoom event path as Apple recommends.
                        .contentShape(Rectangle())
                        .gesture(WindowDragGesture())
                        .allowsWindowActivationEvents()
                        .accessibilityHidden(true)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            sessionToolbarTitleOverlay
        }
        // Applied AFTER the toolbar, manual band, and title so they all belong
        // to the chat column only. The title therefore follows the exact
        // primary-column width, including inspector divider drags, while the
        // inspector presents as its own full-height trailing column with its
        // own toolbar section (divider through the top bar).
        .inspector(isPresented: Binding(
            get: { panelLayout.docksInspector && scratchpad.isVisible },
            set: { visible in
                guard panelLayout.docksInspector else { return }
                scratchpad.setVisible(visible)
            }
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
                // inspector's section of the window toolbar. Use the native
                // toolbar spacer (not a view-layout Spacer) so the toggle stays
                // at the window's trailing edge without forcing the title and
                // button into overflow.
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem(placement: .primaryAction) {
                        scratchpadToggleButton
                    }
                }
        }
        .overlay {
            AdaptiveDrawerLayer(
                isPresented: !panelLayout.docksInspector && panelLayout.activeDrawer == .trailing,
                edge: .trailing,
                width: compactInspectorWidth
            ) {
                SessionInspectorView(controller: controller, scratchpad: scratchpad)
                    .background(theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
            }
        }
        .focusedSceneValue(\.scratchpadToggle, ScratchpadToggleAction(sessionId: session.id) {
            toggleScratchpad()
        })
        .task(id: session.id) {
            store.markOpened(session.id, serverId: session.serverId)
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
            toggleScratchpad()
        } label: {
            Image(systemName: "sidebar.trailing")
        }
        .tooltip("Toggle Scratchpad (⌥⌘I)")
        .accessibilityLabel("Toggle Scratchpad")
        .accessibilityHint("Keyboard shortcut: Option-Command-I")
    }

    private var sessionToolbarTitleOverlay: some View {
        GeometryReader { proxy in
            HStack(spacing: 8) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let diffDirectory {
                    BranchDiffBadge(directory: diffDirectory)
                }
            }
            .padding(.leading, toolbarTitleLeadingInset)
            .padding(.trailing, Self.toolbarTitleTrailingInset)
            .frame(
                width: proxy.size.width,
                height: proxy.safeAreaInsets.top,
                alignment: .leading
            )
            .offset(y: -proxy.safeAreaInsets.top)
        }
        // Preserve the background overlay's native window-drag path and avoid
        // duplicating the window title in the accessibility hierarchy.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var toolbarTitleLeadingInset: CGFloat {
        panelLayout.docksSidebar
            ? Self.dockedToolbarTitleLeadingInset
            : Self.compactToolbarTitleLeadingInset
    }

    private var compactInspectorWidth: CGFloat {
        min(
            max(CGFloat(inspectorWidth), Self.inspectorMinWidth),
            min(Self.inspectorMaxWidth, panelLayout.windowWidth - 16)
        )
    }

    private func toggleScratchpad() {
        if panelLayout.docksInspector {
            scratchpad.toggle()
        } else {
            panelLayout.toggleDrawer(.trailing)
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
