import SwiftUI
import CodevisorCore

/// Hosts a session: resolves its cached `SessionController` from the store
/// and shows the session screen below the native toolbar (which carries the
/// editable workspace name, the diff badge, and the inspector toggle).
struct SessionContainerView: View {
    /// Inspector width limits, shared by the column-width modifier and the
    /// persistence clamp below.
    private static let inspectorMinWidth: CGFloat = 220
    private static let inspectorMaxWidth: CGFloat = 480

    let session: ChatSession
    let project: Project
    let store: SessionStore
    /// Fired when the user's focus lands in a DIFFERENT chat of this
    /// workspace (composer/transcript click, chat tab) — the sidebar
    /// selection follows, keeping the by-chat list in sync with focus.
    /// Non-chat focus (terminals) fires nothing: the last chat stays.
    var onFocusedChatChanged: ((UUID) -> Void)? = nil

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(AdaptivePanelLayout.self) private var panelLayout
    @State private var controller: SessionController?
    /// Cross-group tab dragging, shared by the header pane strip and the
    /// session screen's bottom panel.
    @State private var paneDragCoordinator = PaneTabDragCoordinator()
    /// The session's focus coordinator (composer ⇄ terminals). Owned here so
    /// every center leaf's chat content — any group can host chats — wires
    /// against the same instance.
    @State private var sessionFocus = TerminalFocusController()
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

    /// The workspace's LIVE center tree (the repository isn't observable):
    /// seeded per session, updated by divider drags so the layout re-renders
    /// with what was just persisted.
    @State private var liveCenterTree: SplitNode?

    /// The ACTIVE center group (the one the user last acted in): keyboard
    /// tab commands (⌘T/⌘W/⌘1-9/⌘⌥←→) route here and its bar shows the
    /// ⌘-hints. Defaults to the primary (chat) leaf.
    @State private var activeLeafId: UUID?

    private var inspectorVisible: Bool {
        panelLayout.docksInspector && scratchpad.isVisible
    }

    var body: some View {
        // The inspector is an APP-OWNED trailing column (not the system
        // `.inspector`, whose open animation only fires on the first
        // presentation per mount), so open and close both animate with our
        // one chrome curve.
        HStack(spacing: 0) {
            contentColumn
            if inspectorVisible {
                inspectorColumn
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy(duration: 0.25), value: inspectorVisible)
        // The NATIVE toolbar names the workspace — editable inline, like a
        // document title. Edits pin the name (it stops tracking the primary
        // chat's title).
        .navigationTitle(workspaceName)
        .toolbar {
            if let diffDirectory {
                // A passive counter, not a control: keep it OFF the shared
                // glass platter (otherwise it claims a dead slot in the
                // toggle's capsule — visibly so while the diff is empty).
                ToolbarItem {
                    BranchDiffBadge(directory: diffDirectory)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem {
                Button {
                    toggleScratchpad()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .tooltip("Toggle Scratchpad (⌥⌘I)")
                .accessibilityLabel("Toggle Scratchpad")
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
            // Lifecycle hooks (draft cleanup, dissolution) attach to the
            // primary leaf up front; other leaves get them on first access.
            // The ROUTED chat's leaf starts as the ACTIVE group, with the
            // chat's TAB selected in it (the sidebar picked this chat — it
            // must be the one facing the user, not whichever tab its group
            // last showed).
            if let primaryLeaf = store.workspace(for: session, project: project)
                .centerTree.groupId(containingChat: session.id) {
                let model = configuredCenterModel(leafId: primaryLeaf)
                if let chatPane = model.state.panes.first(where: {
                    $0.kind == .chat && $0.chatSessionId == session.id
                }), model.state.selectedPaneId != chatPane.id {
                    model.select(id: chatPane.id)
                }
                // Unconditional: with workspace-keyed identity this task
                // re-runs for every routed-chat change WITHOUT a remount,
                // and the newly routed chat's group takes over.
                activateLeaf(primaryLeaf)
                // The routed chat's composer takes keyboard focus — now if
                // it's already registered, else the moment its (possibly
                // later-laid-out) pane registers it.
                sessionFocus.requestComposerFocus(forChat: session.id)
            } else if let firstLeaf = store.workspace(for: session, project: project)
                .centerTree.allGroups.first?.id {
                // A CHAT-LESS workspace (every chat closed/archived; routed
                // here through the grow-only session index): the first
                // group takes over as the keyboard target.
                _ = configuredCenterModel(leafId: firstLeaf)
                activateLeaf(firstLeaf)
            }
            // Cross-group drops: bar inserts, content joins, and splits.
            paneDragCoordinator.onResolve = { paneId, source, resolution in
                resolvePaneDrop(paneId: paneId, source: source, resolution: resolution)
            }
            // ⌘W's window-close guard: repo truth on whether tabs remain.
            sessionFocus.hasOtherCenterTabs = { [store] in
                store.workspace(for: session, project: project)
                    .centerTree.allGroups.flatMap(\.state.panes).count > 1
            }
            // Upward focus feedback: clicking into any chat's composer
            // makes its group the active one (terminals do the same through
            // their surface responder callbacks) — and the sidebar's chat
            // selection follows the focused chat.
            sessionFocus.onChatComposerFocused = { chatId in
                if let leaf = store.workspace(for: session, project: project)
                    .centerTree.groupId(containingChat: chatId),
                   leaf != activeLeafId {
                    activateLeaf(leaf)
                }
                if chatId != session.id {
                    onFocusedChatChanged?(chatId)
                }
            }
            store.markOpened(session.id, serverId: session.serverId)
            let controller = store.controller(for: session, project: project)
            self.controller = controller
            // UNSTARTED chats (eagerly created records with no first message
            // yet) must not connect here: connecting launches an agent with
            // the DEFAULT harness, silently making the choice their new-chat
            // composer still offers. Their first send owns the connection.
            guard session.agentSessionId != nil || controller.isConnected else { return }
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

    /// The session content: every pane group renders its own tab bar (the
    /// Finder model — tabs are a content band below the native toolbar).
    /// The EXPLICIT page fill matters: the bare NavigationSplitView detail
    /// surface is the NSWindow background, which desktop tinting shifts a
    /// few shades — the terminal's opaque surface can't follow that, so
    /// both sides paint the same resolved color instead.
    private var contentColumn: some View {
        Group {
            if let controller {
                let workspace = store.workspace(for: session, project: project)
                SessionScreen(
                    controller: controller,
                    paneGroup: store.paneGroup(for: session, project: project),
                    centerGroup: store.centerPaneGroup(for: session, project: project),
                    dragCoordinator: paneDragCoordinator,
                    focus: sessionFocus,
                    centerTree: liveCenterTree ?? workspace.centerTree,
                    primaryLeafId: workspace.centerTree.groupId(containingChat: session.id),
                    activeLeafId: activeLeafId,
                    centerLeafModel: { leafId in configuredCenterModel(leafId: leafId) },
                    chatTitleLookup: chatPaneTitle,
                    onCenterTreeChanged: { tree in
                        liveCenterTree = tree
                        store.saveCenterTree(tree, workspaceId: workspace.id)
                    },
                    // Divider mid-drag: render-only re-layout.
                    onCenterTreeLiveChanged: { tree in
                        liveCenterTree = tree
                    }
                )
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // System theme: NO fill — the window's live tinted backdrop is the
        // one surface behind chat, tab band, and (transparent) terminal
        // alike. Custom palettes paint their own page color.
        .background(theme.isSystem ? Color.clear : theme.windowBackground)
    }

    /// The workspace's name as an editable window title: edits save through
    /// the repository with `hasCustomName` pinned (the automatic name stops
    /// tracking the primary chat's title).
    private var workspaceName: Binding<String> {
        Binding(
            get: { store.workspace(for: session, project: project).name },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                var workspace = store.workspace(for: session, project: project)
                guard workspace.name != trimmed else { return }
                workspace.name = trimmed
                workspace.hasCustomName = true
                environment.workspaces.save(workspace)
            }
        )
    }

    /// The group model behind a drop ref.
    private func groupModel(for ref: PaneGroupRef) -> PaneGroupModel {
        switch ref {
        case .bottom:
            return store.paneGroup(for: session, project: project)
        case let .centerLeaf(leafId):
            return configuredCenterModel(leafId: leafId)
        }
    }

    /// A center leaf's model with the container's lifecycle hooks attached
    /// (idempotent — models are cached).
    private func configuredCenterModel(leafId: UUID) -> PaneGroupModel {
        let model = store.centerGroup(
            leafId: leafId,
            workspace: store.workspace(for: session, project: project),
            session: session,
            project: project
        )
        // Acting in a group makes it the ACTIVE one: keyboard tab commands
        // follow the user (routed via the focus controller's centerGroup).
        model.onActivated = { [weak model] in
            guard activeLeafId != leafId else { return }
            activeLeafId = leafId
            if let model {
                sessionFocus.centerGroup = model
            }
        }
        // Selecting a chat tab focuses ITS composer — keyed and deferred,
        // since switching tabs remounts the chat and the composer registers
        // a tick later. ONLY chat panes: any other selected kind (New Tab
        // placeholder) must not steal focus into some arbitrary composer.
        // ⌘J relays to the session screen's toggle.
        model.requestComposerFocus = { [weak model] in
            guard let selected = model?.state.selectedPane, selected.kind == .chat else { return }
            if let chatId = selected.chatSessionId {
                sessionFocus.requestComposerFocus(forChat: chatId)
            } else {
                sessionFocus.focusComposer()
            }
        }
        model.requestToggle = {
            sessionFocus.requestPanelToggle?()
        }
        model.onPaneClosed = { descriptor in
            if descriptor.kind == .chat {
                if let closedSessionId = descriptor.chatSessionId {
                    // Closing an established chat's tab ARCHIVES its
                    // session (recoverable from the archived list); the
                    // session itself always survives.
                    if let closed = environment.projectList.sessions.first(where: {
                        $0.serverId == session.serverId && $0.id == closedSessionId
                    }) {
                        environment.projectList.archiveSession(closed)
                    }
                    // The ROUTED chat left: hand the route to the
                    // workspace's first surviving chat, so the sidebar
                    // never points at an archived session (focus may land
                    // on a terminal, which reports nothing).
                    if closedSessionId == session.id,
                       let survivor = store.workspace(for: session, project: project)
                        .centerTree.allGroups
                        .flatMap(\.state.panes)
                        .first(where: { $0.kind == .chat && $0.chatSessionId != nil })?
                        .chatSessionId {
                        onFocusedChatChanged?(survivor)
                    }
                } else {
                    // A draft closed unsent: discard its composer state.
                    store.removePaneDraft(paneId: descriptor.id)
                }
            }
            // Closing a group's last tab dissolves the group.
            dissolveIfEmpty(leafId: leafId)
        }
        // A lone New Tab placeholder's close dissolves its group — possible
        // whenever the workspace has other groups.
        model.canDissolve = {
            store.workspace(for: session, project: project).centerTree.allGroups.count > 1
        }
        // Any center group can host chats (established or draft) and the
        // New Tab placeholder. Weak model: the closure is held BY the model.
        // Re-wired UNCONDITIONALLY (safe: @ObservationIgnored): the models
        // are cached across containers, and this closure captures THIS
        // container's focus controller — a stale capture makes every chat
        // pane register its composer with a dead controller, orphaning the
        // new container's focus intents.
        model.chatContent = { [weak model] descriptor in
            if descriptor.kind == .newTab {
                return AnyView(NewTabPageView(
                    paneId: descriptor.id,
                    group: model,
                    onNewChat: { [weak model] in
                        createChat(convertingPlaceholder: descriptor.id, in: model)
                    }
                ))
            }
            return AnyView(chatPaneContent(
                descriptor: descriptor, group: model, focus: sessionFocus
            ))
        }
        return model
    }

    /// "New Chat" from a New tab page: creates the SESSION eagerly — a real
    /// chat from birth (sidebar row, archive-on-close, focus-follow), not a
    /// deferred draft — running in the workspace's directory with the
    /// default harness, then converts the placeholder in place.
    private func createChat(convertingPlaceholder paneId: UUID, in model: PaneGroupModel?) {
        guard let model else { return }
        let workspace = store.workspace(for: session, project: project)
        let created = environment.projectList.newSession(
            in: project,
            title: "New Chat",
            cwd: workspace.rootDirectory
        )
        model.convertNewTabPane(
            id: paneId, to: .chat,
            chatSessionId: created.id, name: created.title
        )
        // The pane's composer takes focus once it mounts; the responder
        // observer then walks the sidebar selection over to the new chat.
        sessionFocus.requestComposerFocus(forChat: created.id)
    }

    /// Removes an emptied center leaf from the tree: siblings absorb its
    /// share, single-child splits collapse (VS Code's rule). The workspace's
    /// LAST group can't dissolve — Chrome's rule instead: its empty state
    /// becomes a "New tab" placeholder tab, so the strip never empties.
    private func dissolveIfEmpty(leafId: UUID) {
        let workspace = store.workspace(for: session, project: project)
        let model = store.centerGroup(
            leafId: leafId, workspace: workspace, session: session, project: project
        )
        guard model.state.panes.isEmpty else { return }
        // Repo truth, never the render cache — group states in
        // liveCenterTree go stale as models persist.
        if let pruned = workspace.centerTree.removingGroup(id: leafId) {
            liveCenterTree = pruned
            store.saveCenterTree(pruned, workspaceId: workspace.id)
            paneDragCoordinator.clearGeometry(for: .centerLeaf(leafId))
            paneDragCoordinator.clearContentFrame(leafId: leafId)
            store.evictCenterLeaf(workspaceId: workspace.id, leafId: leafId)
            // A dissolved active group hands the keyboard back to the
            // primary (chat) leaf.
            if activeLeafId == leafId {
                activateLeaf(pruned.groupId(containingChat: session.id) ?? pruned.allGroups.first?.id)
            }
        } else {
            model.addNewTabPane()
        }
    }

    /// Makes a leaf the active group (keyboard routing + hints).
    private func activateLeaf(_ leafId: UUID?) {
        activeLeafId = leafId
        if let leafId {
            sessionFocus.centerGroup = configuredCenterModel(leafId: leafId)
        }
    }

    /// Performs a resolved cross-group drop: extracts the LIVE pane from its
    /// source (the terminal keeps its PTY), then inserts it into the target
    /// bar slot, appends it to a group (content-center join), or splits a
    /// leaf with it. A center leaf left empty dissolves out of the tree
    /// (its siblings absorb the space — VS Code's rule).
    private func resolvePaneDrop(
        paneId: UUID,
        source: PaneGroupRef,
        resolution: PaneDropResolution
    ) {
        let workspace = store.workspace(for: session, project: project)
        let sourceModel = groupModel(for: source)
        guard let (descriptor, livePane) = sourceModel.extractPane(id: paneId) else { return }

        let destination: PaneGroupModel
        switch resolution {
        case let .bar(ref, index):
            destination = groupModel(for: ref)
            destination.adoptPane(descriptor, live: livePane, at: index)
        case let .join(ref):
            destination = groupModel(for: ref)
            destination.adoptPane(descriptor, live: livePane, at: Int.max)
        case let .split(leafId, edge):
            let newGroupId = UUID()
            // Re-read the tree AFTER the extraction: the extract just
            // persisted the source group's new state into the workspace, and
            // splitting a pre-extract snapshot would resurrect the moved
            // pane in its old group.
            let tree = store.workspace(for: session, project: project).centerTree.splitting(
                groupId: leafId,
                edge: edge,
                newGroupId: newGroupId,
                // The group is born empty; adoptPane below inserts the pane
                // and registers its live object in one path.
                newGroupState: PaneGroupState(isVisible: true)
            )
            liveCenterTree = tree
            store.saveCenterTree(tree, workspaceId: workspace.id)
            destination = groupModel(for: .centerLeaf(newGroupId))
            destination.adoptPane(descriptor, live: livePane, at: 0)
        }

        // Dissolve an emptied source leaf (never the chat's — the chat can't
        // leave its group, so its leaf can't empty).
        if case let .centerLeaf(sourceLeafId) = source {
            dissolveIfEmpty(leafId: sourceLeafId)
        }

        // The drop was a multi-step operation (extract → mutate tree →
        // adopt → dissolve), and the render cache picked up intermediate
        // snapshots along the way — end on repository truth, always.
        liveCenterTree = store.workspace(for: session, project: project).centerTree

        DispatchQueue.main.async { destination.focusSelectedPane() }
    }

    /// Whether an established chat hasn't truly begun: no agent session ever
    /// created AND no live controller doing so right now. Such chats render
    /// the new-chat composer (harness choice included) even though their
    /// session record exists — eager creation is a sidebar affordance, not a
    /// started conversation. `activeController` is a pure read (body-safe).
    private func isUnstarted(_ chatSession: ChatSession) -> Bool {
        guard chatSession.agentSessionId == nil else { return false }
        guard let live = store.activeController(for: chatSession) else { return true }
        return !(live.isConnected || live.isConnecting || live.isSending)
    }

    /// A chat pane's display title: its referenced session's LIVE title
    /// (auto-titles and renames flow through); drafts show their own name.
    private func chatPaneTitle(_ descriptor: PaneDescriptorState) -> String {
        guard let id = descriptor.chatSessionId else { return descriptor.name }
        return environment.projectList.sessions.first {
            $0.serverId == session.serverId && $0.id == id
        }?.title ?? descriptor.name
    }

    /// A chat pane's content: the referenced session's chat, or (for a
    /// draft) the in-pane new-chat composer that creates the session and
    /// binds it to the pane on first send. Multi-chat workspaces resolve
    /// each pane's controller independently.
    @ViewBuilder
    private func chatPaneContent(
        descriptor: PaneDescriptorState,
        group: PaneGroupModel?,
        focus: TerminalFocusController
    ) -> some View {
        if let chatSessionId = descriptor.chatSessionId {
            if let chatSession = environment.projectList.sessions.first(where: {
                $0.serverId == session.serverId && $0.id == chatSessionId
            }), let chatProject = environment.projectList.projects.first(where: {
                $0.serverId == session.serverId && $0.id == chatSession.projectId
            }) {
                if isUnstarted(chatSession) {
                    // An eagerly created chat that hasn't had its first
                    // message: still the new-chat composer (harness choice
                    // and all) — the session record just already exists for
                    // the sidebar. First send fills it in.
                    NewChatView(
                        store: store,
                        selection: .constant(nil),
                        preferredProjectId: chatProject.id,
                        explicitProjectId: chatProject.id,
                        paneDraftId: descriptor.id,
                        onCreatedInPane: { created in
                            (group ?? store.centerPaneGroup(for: session, project: project))
                                .assignChatSession(
                                    paneId: descriptor.id,
                                    sessionId: created.id,
                                    name: created.title
                                )
                        },
                        preCreatedSession: chatSession,
                        // Setup failure DELETES the session record — the
                        // pane must drop its reference too (a bound pane
                        // over a deleted session is the "no longer exists"
                        // dead end).
                        onSetupFailedInPane: { [weak group] in
                            group?.unbindChatPane(paneId: descriptor.id)
                        }
                    )
                } else {
                    ChatScreen(
                        controller: store.controller(for: chatSession, project: chatProject),
                        focus: focus
                    )
                }
            } else {
                // The referenced session was deleted (e.g. from another
                // device). Offer a fresh start in place instead of a
                // dead end.
                VStack(spacing: 12) {
                    Text("This chat no longer exists")
                        .foregroundStyle(.secondary)
                    Button("Reset Tab") {
                        group?.resetChatPaneToPlaceholder(id: descriptor.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            NewChatView(
                store: store,
                selection: .constant(nil),
                preferredProjectId: project.id,
                explicitProjectId: project.id,
                paneDraftId: descriptor.id,
                onCreatedInPane: { created in
                    // Bind through the pane's OWNING group (the draft may
                    // live in any split leaf, not just the primary).
                    (group ?? store.centerPaneGroup(for: session, project: project))
                        .assignChatSession(
                            paneId: descriptor.id,
                            sessionId: created.id,
                            name: created.title
                        )
                }
            )
        }
    }

    /// The app-owned inspector column: hairline divider, resizable width.
    /// Sits below the native toolbar like the rest of the content.
    private var inspectorColumn: some View {
        SessionInspectorView(controller: controller, scratchpad: scratchpad)
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
