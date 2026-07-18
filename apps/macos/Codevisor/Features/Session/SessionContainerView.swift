import SwiftUI
import CodevisorCore

/// Hosts a session: resolves its cached `SessionController` from the store and
/// shows the session screen under the app-owned header row (the pane tab
/// strip; see WindowChrome.swift for why the app owns its top bar).
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
    @Environment(AdaptivePanelLayout.self) private var panelLayout
    @State private var controller: SessionController?
    /// Cross-group tab dragging, shared by the header pane strip and the
    /// session screen's bottom panel.
    @State private var paneDragCoordinator = PaneTabDragCoordinator()
    /// Last user-chosen inspector width, persisted across the detail
    /// subtree's `.id(session.id)` resets and app relaunches.
    @AppStorage("inspector.width") private var inspectorWidth: Double = 300
    /// The width mid-resize-drag (nil when idle), and the drag's anchor.
    @State private var liveInspectorWidth: CGFloat?
    @State private var inspectorDragStartWidth: CGFloat?

    /// The session's cached scratchpad (cheap dictionary lookup). Holds the
    /// inspector's per-session open state, so it survives the `.id(session.id)`
    /// identity reset in `RootView` and app restarts.
    private var scratchpad: ScratchpadModel {
        store.scratchpad(for: session)
    }

    /// This container's frame in window coordinates (content + inspector).
    @State private var containerFrame: CGRect = .zero

    private var inspectorVisible: Bool {
        panelLayout.docksInspector && scratchpad.isVisible
    }

    /// The header row's live trailing edge in window coordinates (the
    /// inspector divider while open, the window edge while closed).
    @State private var headerMaxX: CGFloat = 0

    /// Trailing gap keeping the + clear of the fixed corner toggle — derived
    /// CONTINUOUSLY from the header's actual trailing edge, so during the
    /// inspector's open/close animation the + holds its ground until the
    /// moving divider genuinely reaches it, then gets pushed along by it
    /// (never teleporting under the toggle).
    private var trailingToggleGap: CGFloat {
        max(0, headerMaxX - containerFrame.maxX + WindowChrome.headerButtonDiameter)
    }

    var body: some View {
        // The inspector is an APP-OWNED trailing column (not the system
        // `.inspector`, whose open animation only fires on the first
        // presentation per mount) — the same ownership move as the top bar,
        // so open and close both animate with our one chrome curve.
        HStack(spacing: 0) {
            contentColumn
            if inspectorVisible {
                inspectorColumn
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy(duration: 0.25), value: inspectorVisible)
        // The header rows ARE the top bar: extend to the true window top.
        // The inspector column's background reaches the top as well.
        .ignoresSafeArea(edges: .top)
        // The window title still names the window (Window menu, Mission
        // Control) even though no titlebar renders it.
        .navigationTitle(session.title)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            containerFrame = frame
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
        // The scratchpad toggle: window-level chrome, fixed in the
        // top-trailing corner whether the inspector is open or closed — only
        // the inspector background moves beneath it. Anchored to the
        // TRAILING edge (which never moves when the LEFT sidebar animates —
        // a leading offset from measured width would drift mid-animation).
        .overlay(alignment: .topTrailing) {
            scratchpadToggleButton
                .frame(height: WindowChrome.headerHeight)
                .padding(.trailing, 10)
                .ignoresSafeArea(edges: .top)
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

    private var contentColumn: some View {
        VStack(spacing: 0) {
            // The app-owned header row: the pane tab strip IS the title (the
            // chat tab shows the session title), plus the branch badge and
            // scratchpad toggle. Ordinary content hosting, so tab clicks,
            // reorders, and tear-out drags behave like any other view.
            DetailHeaderBar {
                PaneGroupBar(
                    group: store.centerPaneGroup(for: session, project: project),
                    dragCoordinator: paneDragCoordinator,
                    chatTabTitle: session.title,
                    // The center group is the tab shortcuts' default target:
                    // they route here unless a bottom terminal holds focus.
                    showsShortcutHints: !store.paneGroup(for: session, project: project).hasFocusedPane
                )
                // Spacing-0 group: an empty diff badge must not claim a
                // spacing slot of its own (it would widen the track-to-+
                // gap past the bar's 18pt leading indent) — the freed width
                // belongs to the tab strip.
                HStack(spacing: 0) {
                    if let diffDirectory {
                        BranchDiffBadge(directory: diffDirectory)
                    }
                    newTerminalButton
                }
                // The fixed corner toggle's footprint, held clear only while
                // the header's trailing edge actually reaches the corner
                // (see trailingToggleGap).
                Color.clear
                    .frame(width: trailingToggleGap)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).maxX
            } action: { maxX in
                headerMaxX = maxX
            }

            Group {
                if let controller {
                    SessionScreen(
                        controller: controller,
                        paneGroup: store.paneGroup(for: session, project: project),
                        centerGroup: store.centerPaneGroup(for: session, project: project),
                        dragCoordinator: paneDragCoordinator
                    )
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// The app-owned inspector column: hairline divider, resizable width,
    /// content below the top-bar band (the fixed corner toggle floats there)
    /// with the column surface reaching the true window top.
    private var inspectorColumn: some View {
        SessionInspectorView(controller: controller, scratchpad: scratchpad)
            .padding(.top, WindowChrome.headerHeight)
            .frame(width: currentInspectorWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(theme.sidebarBackground)
            // The column/content boundary hairline, with the resize grip
            // straddling it.
            .overlay(alignment: .leading) {
                theme.separator
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .overlay(alignment: .leading) { inspectorResizeHandle }
    }

    /// The divider's resize grip: an 8pt strip showing the horizontal-resize
    /// cursor; drags adjust and persist the width (clamped like the native
    /// inspector column).
    private var inspectorResizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = inspectorDragStartWidth ?? currentInspectorWidth
                        inspectorDragStartWidth = start
                        liveInspectorWidth = min(
                            max(start - value.translation.width, Self.inspectorMinWidth),
                            Self.inspectorMaxWidth
                        )
                    }
                    .onEnded { _ in
                        if let liveInspectorWidth {
                            inspectorWidth = Double(liveInspectorWidth)
                        }
                        liveInspectorWidth = nil
                        inspectorDragStartWidth = nil
                    }
            )
    }

    private var currentInspectorWidth: CGFloat {
        liveInspectorWidth ?? min(
            max(CGFloat(inspectorWidth), Self.inspectorMinWidth),
            Self.inspectorMaxWidth
        )
    }

    /// The center group's "new terminal" +, clustered with the window's
    /// other trailing icon buttons (native toolbars group their actions at
    /// the trailing edge — Safari, Xcode) instead of floating after the tabs.
    private var newTerminalButton: some View {
        HeaderIconButton(systemImage: "plus", help: "New Terminal (⌘T)") {
            let group = store.centerPaneGroup(for: session, project: project)
            group.addTerminalPane()
            // Defer until SwiftUI has mounted the new pane's view.
            DispatchQueue.main.async { group.focusSelectedPane() }
        }
    }

    private var scratchpadToggleButton: some View {
        HeaderIconButton(systemImage: "sidebar.trailing", help: "Toggle Scratchpad (⌥⌘I)") {
            toggleScratchpad()
        }
    }

    private var compactInspectorWidth: CGFloat {
        min(
            max(CGFloat(inspectorWidth), Self.inspectorMinWidth),
            min(Self.inspectorMaxWidth, panelLayout.windowWidth - 16)
        )
    }

    private func toggleScratchpad() {
        // NOTE: no withAnimation here — the system `.inspector` presentation
        // manages its own motion, and a custom transaction makes it stall
        // then snap open. (The transient drawer animates internally.)
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
