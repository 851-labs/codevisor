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
    /// Global geometry + pointer state for rearranging split leaves inside
    /// the selected top tab by dragging their headers.
    @State private var splitDragCoordinator = WorkspaceSplitDragCoordinator()
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
    /// Repository writes are intentionally non-observable. Structural tab
    /// changes bump this token so the strip and selected tree re-read truth.
    @State private var workspaceRevision = 0
    /// Suppresses per-leaf dissolve while a whole top tab is closing.
    @State private var closingCenterTabId: UUID?

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
                .help("Toggle Scratchpad (⌥⌘I)")
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
                    .themedSurface(.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
            }
        }
        .focusedSceneValue(\.scratchpadToggle, ScratchpadToggleAction(sessionId: session.id) {
            toggleScratchpad()
        })
        .focusedSceneValue(
            \.workspaceLayoutActions,
            WorkspaceLayoutActions(
                workspaceId: store.workspace(for: session, project: project).id,
                newTab: addCenterTab,
                closeSplit: closeActiveLeaf,
                closeTab: {
                    let workspace = store.workspace(for: session, project: project)
                    closeCenterTab(workspace.selectedCenterTabId)
                },
                previousTab: { selectRelativeCenterTab(offset: -1) },
                nextTab: { selectRelativeCenterTab(offset: 1) },
                previousSplit: { focusRelativeSplit(offset: -1) },
                nextSplit: { focusRelativeSplit(offset: 1) },
                split: splitActiveLeaf,
                focus: focusAdjacentLeaf
            )
        )
        // Background tasks that stream through a server-owned terminal get a
        // tab in the bottom panel — a dev server is something running, not
        // something a chat is waiting on. Synced at the WORKSPACE level
        // across EVERY chat's controller (the panel is shared), with prunes
        // scoped to each task's owning chat, so switching chats never tears
        // down a sibling's tab. Reading the fingerprint in body keeps the
        // observation live for all cached controllers.
        .onChange(of: backgroundTaskFingerprint, initial: true) { _, _ in
            syncWorkspaceBackgroundTerminals()
        }
        .task(id: session.id) {
            splitDragCoordinator.canResolve = { sourceLeafId, resolution, canvasSize in
                canMoveSplitLeaf(
                    sourceLeafId,
                    relativeTo: resolution.targetLeafId,
                    edge: resolution.edge,
                    canvasSize: canvasSize
                )
            }
            splitDragCoordinator.onResolve = { sourceLeafId, resolution in
                moveSplitLeaf(
                    sourceLeafId,
                    relativeTo: resolution.targetLeafId,
                    edge: resolution.edge
                )
            }
            // Lifecycle hooks (draft cleanup, dissolution) attach to the
            // primary leaf up front; other leaves get them on first access.
            // The ROUTED chat's leaf starts as the ACTIVE group, with the
            // chat's TAB selected in it (the sidebar picked this chat — it
            // must be the one facing the user, not whichever tab its group
            // last showed).
            var routedWorkspace = store.workspace(for: session, project: project)
            let liveRoutedSession = environment.projectList.sessions.first {
                $0.serverId == session.serverId && $0.id == session.id
            } ?? session
            // A chat removed by closing its old pane keeps its grow-only
            // workspace index. If it is later restored/unarchived, route it
            // back into that workspace as a fresh single-chat top tab.
            if !liveRoutedSession.isArchived,
               routedWorkspace.tabId(containingChat: session.id) == nil {
                let tab = WorkspaceTab(root: .leaf(.centerInitial(sessionId: session.id)))
                routedWorkspace.centerTabs.append(tab)
                routedWorkspace.selectedCenterTabId = tab.id
                environment.workspaces.save(routedWorkspace)
                workspaceRevision += 1
                liveCenterTree = tab.root
            }
            if let routedTabId = routedWorkspace.tabId(containingChat: session.id),
               routedWorkspace.selectedCenterTabId != routedTabId {
                routedWorkspace.selectedCenterTabId = routedTabId
                environment.workspaces.save(routedWorkspace)
                workspaceRevision += 1
                liveCenterTree = routedWorkspace.centerTree
            }
            if let primaryLeaf = routedWorkspace.centerTree.groupId(containingChat: session.id) {
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
                // The routed chat's composer takes keyboard focus — now
                // if it's already registered, else the moment its
                // (possibly later-laid-out) pane registers it.
                sessionFocus.requestComposerFocus(forChat: session.id)
            } else if let firstLeaf = routedWorkspace.centerTree.allGroups.first?.id {
                // A legacy or draft CHAT-LESS workspace routed here through
                // the grow-only session index uses its first group as the
                // keyboard target.
                _ = configuredCenterModel(leafId: firstLeaf)
                activateLeaf(firstLeaf)
            }
            // Bottom-panel spawns from its local + action follow the focused
            // center context too.
            store.paneGroup(for: session, project: project).defaultSpawnCwd = {
                focusedSpawnCwd()
            }
            store.paneGroup(for: session, project: project).workspaceCommandHandler = { command in
                switch command {
                case .newTab, .previousTab, .nextTab, .selectTab, .split, .focusSplit,
                     .previousSplit, .nextSplit:
                    return handleWorkspaceCommand(command)
                case .closeTab, .togglePanel:
                    return false
                }
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

    /// The session content: a browser-style tab bar above the selected
    /// tab's split layout.
    /// The EXPLICIT page fill matters: the bare NavigationSplitView detail
    /// surface is the NSWindow background, which desktop tinting shifts a
    /// few shades — the terminal's opaque surface can't follow that, so
    /// both sides paint the same resolved color instead.
    private var contentColumn: some View {
        Group {
            if let controller {
                let _ = workspaceRevision
                let workspace = store.workspace(for: session, project: project)
                VStack(spacing: 0) {
                    if workspace.centerTabs.count > 1 {
                        WorkspaceTabBar(
                            tabs: workspace.centerTabs,
                            selectedTabId: workspace.selectedCenterTabId,
                            title: workspaceTabTitle,
                            descriptor: workspaceTabDescriptor,
                            onSelect: selectCenterTab,
                            onClose: closeCenterTab,
                            onMove: moveCenterTab,
                            onRename: renameCenterTab,
                            onNew: addCenterTab
                        )
                    }
                    SessionScreen(
                        controller: controller,
                        paneGroup: store.paneGroup(for: session, project: project),
                        centerGroup: activeCenterModel(in: workspace),
                        focus: sessionFocus,
                        centerTree: liveCenterTree ?? workspace.centerTree,
                        primaryLeafId: workspace.centerTree.groupId(containingChat: session.id),
                        activeLeafId: activeLeafId ?? workspace.selectedCenterTab?.activeLeafId,
                        centerLeafModel: { leafId in configuredCenterModel(leafId: leafId) },
                        centerPaneTitle: paneTitle,
                        sessionStore: store,
                        splitDragCoordinator: splitDragCoordinator,
                        onSplitLeaf: splitLeaf,
                        onRenameLeaf: renameLeaf,
                        onCloseLeaf: closeLeaf,
                        onCenterTreeChanged: { tree in
                            liveCenterTree = tree
                            saveSelectedTree(tree, workspaceId: workspace.id)
                        },
                        onCenterTreeLiveChanged: { tree in liveCenterTree = tree }
                    )
                }
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
        // The hairline under the top bar: drawn by the CENTER panel's top
        // edge (the inspector and sidebar stay seamless under the toolbar).
        .overlay(alignment: .top) {
            theme.separator
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    /// The workspace's name as an editable window title: edits save through
    /// the repository with `hasCustomName` pinned so later worktree creation
    /// does not replace it.
    private var workspaceName: Binding<String> {
        Binding(
            get: { store.workspace(for: session, project: project).name },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                var workspace = store.workspace(for: session, project: project)
                guard workspace.name != trimmed || !workspace.hasCustomName else { return }
                workspace.name = trimmed
                workspace.hasCustomName = true
                environment.workspaces.save(workspace)
            }
        )
    }

    // MARK: - Workspace tabs and split commands

    private func activeCenterModel(in workspace: Workspace) -> PaneGroupModel {
        let leafId = activeLeafId
            ?? workspace.selectedCenterTab?.activeLeafId
            ?? workspace.centerTree.allGroups.first!.id
        return configuredCenterModel(leafId: leafId)
    }

    private func workspaceTabDescriptor(_ tab: WorkspaceTab) -> PaneDescriptorState? {
        configuredCenterModel(leafId: tab.activeLeafId).state.selectedPane
            ?? tab.root.group(id: tab.activeLeafId)?.selectedPane
            ?? tab.root.allGroups.first?.state.selectedPane
    }

    private func workspaceTabTitle(_ tab: WorkspaceTab) -> String {
        if let customTitle = tab.customTitle {
            return customTitle
        }
        guard let descriptor = workspaceTabDescriptor(tab) else { return "New Tab" }
        return paneTitle(descriptor)
    }

    private func selectCenterTab(_ tabId: UUID) {
        var workspace = store.workspace(for: session, project: project)
        guard let tab = workspace.centerTabs.first(where: { $0.id == tabId }) else { return }
        if let old = workspace.selectedCenterTab, old.id != tabId {
            for leaf in old.root.allGroups {
                configuredCenterModel(leafId: leaf.id).selectedPane?.visibilityChanged(false)
            }
        }
        workspace.selectedCenterTabId = tabId
        environment.workspaces.save(workspace)
        workspaceRevision += 1
        liveCenterTree = tab.root
        activateLeaf(tab.activeLeafId)
        let model = configuredCenterModel(leafId: tab.activeLeafId)
        model.selectedPane?.visibilityChanged(true)
        DispatchQueue.main.async { model.focusSelectedPane() }
    }

    private func addCenterTab() {
        var workspace = store.workspace(for: session, project: project)
        if let current = workspace.selectedCenterTab {
            for leaf in current.root.allGroups {
                configuredCenterModel(leafId: leaf.id).selectedPane?.visibilityChanged(false)
            }
        }
        var state = PaneGroupState()
        _ = state.addNewTabPane(inheritedCwd: focusedSpawnCwd())
        let tab = WorkspaceTab(root: .leaf(state))
        workspace.centerTabs.append(tab)
        workspace.selectedCenterTabId = tab.id
        environment.workspaces.save(workspace)
        workspaceRevision += 1
        liveCenterTree = tab.root
        activateLeaf(tab.activeLeafId)
    }

    private func moveCenterTab(_ sourceId: UUID, _ targetId: UUID) {
        var workspace = store.workspace(for: session, project: project)
        guard sourceId != targetId,
              let source = workspace.centerTabs.firstIndex(where: { $0.id == sourceId }),
              let target = workspace.centerTabs.firstIndex(where: { $0.id == targetId }) else { return }
        let tab = workspace.centerTabs.remove(at: source)
        workspace.centerTabs.insert(tab, at: target)
        environment.workspaces.save(workspace)
        workspaceRevision += 1
    }

    private func renameCenterTab(_ tabId: UUID, to customTitle: String?) {
        var workspace = store.workspace(for: session, project: project)
        guard let index = workspace.centerTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        guard workspace.centerTabs[index].customTitle != normalized else { return }
        workspace.centerTabs[index].customTitle = normalized
        environment.workspaces.save(workspace)
        workspaceRevision += 1
    }

    private func closeCenterTab(_ tabId: UUID) {
        var workspace = store.workspace(for: session, project: project)
        guard let index = workspace.centerTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closing = workspace.centerTabs[index]
        let closesRoutedChat = closing.root.allGroups.contains { group in
            group.state.panes.contains { $0.chatSessionId == session.id }
        }
        closingCenterTabId = tabId
        for leaf in closing.root.allGroups {
            let model = configuredCenterModel(leafId: leaf.id)
            if let paneId = model.state.selectedPaneId {
                model.closePane(id: paneId)
            }
            store.evictCenterLeaf(workspaceId: workspace.id, leafId: leaf.id)
        }
        closingCenterTabId = nil

        // Re-read after each leaf persisted its empty group, then remove the
        // whole layout atomically from repository truth.
        workspace = store.workspace(for: session, project: project)
        guard let refreshedIndex = workspace.centerTabs.firstIndex(where: { $0.id == tabId }) else {
            return
        }
        workspace.centerTabs.remove(at: refreshedIndex)
        if workspace.centerTabs.isEmpty {
            var state = PaneGroupState()
            _ = state.addNewTabPane(inheritedCwd: workspace.rootDirectory)
            let replacement = WorkspaceTab(root: .leaf(state))
            workspace.centerTabs = [replacement]
            workspace.selectedCenterTabId = replacement.id
        } else if workspace.selectedCenterTabId == tabId {
            workspace.selectedCenterTabId = workspace.centerTabs[
                min(refreshedIndex, workspace.centerTabs.count - 1)
            ].id
        }
        environment.workspaces.save(workspace)
        workspaceRevision += 1
        liveCenterTree = workspace.centerTree
        activateLeaf(workspace.selectedCenterTab?.activeLeafId)
        if closesRoutedChat, let survivor = firstSurvivingChatId() {
            onFocusedChatChanged?(survivor)
        }
    }

    private func saveSelectedTree(_ tree: SplitNode, workspaceId: UUID) {
        guard var workspace = environment.workspaces.workspace(id: workspaceId),
              let index = workspace.selectedCenterTabIndex else { return }
        // Divider callbacks carry render-time topology/fractions. Merge the
        // repository's live leaf states so a recent New Tab conversion or
        // title/session binding can never be overwritten by a resize.
        var merged = tree
        for group in workspace.centerTabs[index].root.allGroups {
            merged = merged.updatingGroup(id: group.id) { _ in group.state }
        }
        workspace.centerTabs[index].root = merged
        if merged.group(id: workspace.centerTabs[index].activeLeafId) == nil,
           let first = merged.allGroups.first?.id {
            workspace.centerTabs[index].activeLeafId = first
        }
        environment.workspaces.save(workspace)
        workspaceRevision += 1
    }

    private func handleWorkspaceCommand(_ command: PaneGroupCommand) -> Bool {
        switch command {
        case .newTab:
            addCenterTab()
        case .previousTab:
            selectRelativeCenterTab(offset: -1)
        case .nextTab:
            selectRelativeCenterTab(offset: 1)
        case let .selectTab(index):
            let workspace = store.workspace(for: session, project: project)
            guard workspace.centerTabs.indices.contains(index) else { return true }
            selectCenterTab(workspace.centerTabs[index].id)
        case let .split(edge):
            splitActiveLeaf(edge: edge)
        case let .focusSplit(edge):
            focusAdjacentLeaf(edge: edge)
        case .previousSplit:
            focusRelativeSplit(offset: -1)
        case .nextSplit:
            focusRelativeSplit(offset: 1)
        case .closeTab:
            closeActiveLeaf()
        case .togglePanel:
            return false
        }
        return true
    }

    private func selectRelativeCenterTab(offset: Int) {
        let workspace = store.workspace(for: session, project: project)
        guard workspace.centerTabs.count > 1,
              let index = workspace.selectedCenterTabIndex else { return }
        let target = (index + offset + workspace.centerTabs.count) % workspace.centerTabs.count
        selectCenterTab(workspace.centerTabs[target].id)
    }

    private func splitActiveLeaf(edge: SplitEdge) {
        let workspace = store.workspace(for: session, project: project)
        guard let tab = workspace.selectedCenterTab else { return }
        splitLeaf(activeLeafId ?? tab.activeLeafId, edge: edge)
    }

    /// Splits the explicitly targeted leaf. Header buttons call this with
    /// their owning leaf; keyboard/menu commands pass the active leaf.
    private func splitLeaf(_ leafId: UUID, edge: SplitEdge) {
        var workspace = store.workspace(for: session, project: project)
        guard let tabIndex = workspace.centerTabs.firstIndex(where: {
            $0.root.group(id: leafId) != nil
        }) else { return }
        let inheritedCwd = spawnCwd(for: leafId, in: workspace)
        var state = PaneGroupState()
        _ = state.addNewTabPane(inheritedCwd: inheritedCwd)
        let newLeafId = UUID()
        workspace.centerTabs[tabIndex].root = workspace.centerTabs[tabIndex].root.splitting(
            groupId: leafId,
            edge: edge,
            newGroupId: newLeafId,
            newGroupState: state
        )
        workspace.centerTabs[tabIndex].activeLeafId = newLeafId
        environment.workspaces.save(workspace)
        workspaceRevision += 1
        liveCenterTree = workspace.centerTabs[tabIndex].root
        activateLeaf(newLeafId)
    }

    /// Atomically relocates one whole leaf inside the selected top tab. The
    /// group id survives, so its cached model and any live terminal surface
    /// move with the layout instead of being torn down and recreated.
    private func moveSplitLeaf(_ sourceLeafId: UUID, relativeTo targetLeafId: UUID, edge: SplitEdge) {
        var workspace = store.workspace(for: session, project: project)
        guard let tabIndex = workspace.selectedCenterTabIndex else { return }
        let current = workspace.centerTabs[tabIndex].root
        guard current.group(id: sourceLeafId) != nil,
              current.group(id: targetLeafId) != nil else { return }

        let moved = current.movingGroup(
            id: sourceLeafId,
            relativeTo: targetLeafId,
            edge: edge
        )
        guard moved != current else { return }

        workspace.centerTabs[tabIndex].root = moved
        workspace.centerTabs[tabIndex].activeLeafId = sourceLeafId
        environment.workspaces.save(workspace)
        workspaceRevision += 1
        liveCenterTree = moved
        activateLeaf(sourceLeafId)

        DispatchQueue.main.async {
            configuredCenterModel(leafId: sourceLeafId).focusSelectedPane()
        }
    }

    /// Validates the POST-move topology. A same-row reorder can be valid even
    /// when the hovered leaf itself is too narrow to halve before the source
    /// is removed; evaluating the candidate avoids hiding those targets.
    private func canMoveSplitLeaf(
        _ sourceLeafId: UUID,
        relativeTo targetLeafId: UUID,
        edge: SplitEdge,
        canvasSize: CGSize
    ) -> Bool {
        let workspace = store.workspace(for: session, project: project)
        guard let current = workspace.selectedCenterTab?.root,
              canvasSize.width > 0,
              canvasSize.height > 0 else { return false }
        let candidate = current.movingGroup(
            id: sourceLeafId,
            relativeTo: targetLeafId,
            edge: edge
        )
        guard candidate != current else { return false }

        let currentFrames = normalizedLeafFrames(current).values
        let candidateFrames = normalizedLeafFrames(candidate).values
        guard let currentMinWidth = currentFrames.map({ $0.width * canvasSize.width }).min(),
              let currentMinHeight = currentFrames.map({ $0.height * canvasSize.height }).min()
        else { return false }

        // A window may already be smaller than the nominal pane floor. In
        // that case permit moves that do not make its smallest pane worse.
        let requiredWidth = min(WorkspaceSplitDragCoordinator.minChildWidth, currentMinWidth)
        let requiredHeight = min(WorkspaceSplitDragCoordinator.minChildHeight, currentMinHeight)
        return candidateFrames.allSatisfy { frame in
            frame.width * canvasSize.width >= requiredWidth - 1
                && frame.height * canvasSize.height >= requiredHeight - 1
        }
    }

    private func closeActiveLeaf() {
        let workspace = store.workspace(for: session, project: project)
        guard let tab = workspace.selectedCenterTab else { return }
        closeLeaf(activeLeafId ?? tab.activeLeafId)
    }

    private func closeLeaf(_ leafId: UUID) {
        let model = configuredCenterModel(leafId: leafId)
        guard let paneId = model.state.selectedPaneId else { return }
        model.closePane(id: paneId)
    }

    private func renameLeaf(_ leafId: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let model = configuredCenterModel(leafId: leafId)
        guard let descriptor = model.state.selectedPane else { return }
        model.renamePane(id: descriptor.id, to: trimmed)
        if descriptor.kind == .chat,
           let chatId = descriptor.chatSessionId,
           let chat = environment.projectList.sessions.first(where: {
               $0.serverId == session.serverId && $0.id == chatId
           }) {
            environment.projectList.renameSession(chat, to: trimmed)
        }
    }

    private func focusAdjacentLeaf(edge: SplitEdge) {
        let workspace = store.workspace(for: session, project: project)
        guard let tab = workspace.selectedCenterTab else { return }
        let current = activeLeafId ?? tab.activeLeafId
        let frames = normalizedLeafFrames(tab.root)
        guard let source = frames[current] else { return }
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        let candidates = frames.filter { id, frame in
            guard id != current else { return false }
            switch edge {
            case .leading: return frame.midX < sourceCenter.x
            case .trailing: return frame.midX > sourceCenter.x
            case .top: return frame.midY < sourceCenter.y
            case .bottom: return frame.midY > sourceCenter.y
            }
        }
        let target = candidates.min { lhs, rhs in
            let ld = hypot(lhs.value.midX - sourceCenter.x, lhs.value.midY - sourceCenter.y)
            let rd = hypot(rhs.value.midX - sourceCenter.x, rhs.value.midY - sourceCenter.y)
            return ld < rd
        }?.key
        guard let target else { return }
        activateLeaf(target)
        DispatchQueue.main.async { configuredCenterModel(leafId: target).focusSelectedPane() }
    }

    /// Cycles through split leaves in stable visual reading order. This is
    /// deliberately independent of split orientation so ⌘[ / ⌘] remains
    /// predictable in nested horizontal and vertical layouts.
    private func focusRelativeSplit(offset: Int) {
        let workspace = store.workspace(for: session, project: project)
        guard let tab = workspace.selectedCenterTab else { return }
        let leaves = tab.root.allGroups.map(\.id)
        guard leaves.count > 1 else { return }
        let current = activeLeafId ?? tab.activeLeafId
        let index = leaves.firstIndex(of: current) ?? 0
        let target = leaves[(index + offset + leaves.count) % leaves.count]
        activateLeaf(target)
        DispatchQueue.main.async { configuredCenterModel(leafId: target).focusSelectedPane() }
    }

    private func normalizedLeafFrames(_ root: SplitNode) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        func walk(_ node: SplitNode, in frame: CGRect) {
            switch node {
            case let .group(id, _):
                result[id] = frame
            case let .split(orientation, children):
                var cursor: CGFloat = 0
                for child in children {
                    let fraction = CGFloat(child.fraction)
                    let childFrame: CGRect
                    if orientation == .horizontal {
                        childFrame = CGRect(
                            x: frame.minX + frame.width * cursor, y: frame.minY,
                            width: frame.width * fraction, height: frame.height
                        )
                    } else {
                        childFrame = CGRect(
                            x: frame.minX, y: frame.minY + frame.height * cursor,
                            width: frame.width, height: frame.height * fraction
                        )
                    }
                    walk(child.node, in: childFrame)
                    cursor += fraction
                }
            }
        }
        walk(root, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return result
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
            activateLeaf(leafId)
            if let model {
                sessionFocus.centerGroup = model
            }
        }
        model.workspaceCommandHandler = { command in
            handleWorkspaceCommand(command)
        }
        // cwd follows focus: ⌘T / bar "+" spawns inherit the focused pane's
        // context (a worktree chat's terminal opens in the worktree).
        model.defaultSpawnCwd = { focusedSpawnCwd() }
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
        model.requestBackgroundFocus = {
            sessionFocus.focusPaneBackground()
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
                        environment.archiveSession(closed)
                    }
                    // The ROUTED chat left: hand the route to the
                    // workspace's first surviving chat, so the sidebar
                    // never points at an archived session (focus may land
                    // on a terminal, which reports nothing).
                    if closedSessionId == session.id,
                       closingCenterTabId == nil,
                       let survivor = firstSurvivingChatId() {
                        onFocusedChatChanged?(survivor)
                    }
                } else {
                    // A draft closed unsent: discard its composer state.
                    store.removePaneDraft(paneId: descriptor.id)
                }
            }
            if closingCenterTabId == nil {
                dissolveIfEmpty(leafId: leafId)
            }
        }
        // A lone New Tab placeholder's close dissolves its group — possible
        // whenever the workspace has other groups.
        model.canDissolve = { true }
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
                    contexts: workspaceRunContexts(),
                    inheritedPath: descriptor.cwdOverride,
                    onNewChat: { [weak model] context in
                        createChat(
                            convertingPlaceholder: descriptor.id,
                            in: model,
                            context: context
                        )
                    }
                ))
            }
            return AnyView(chatPaneContent(
                descriptor: descriptor, group: model, focus: sessionFocus
            ))
        }
        return model
    }

    /// The cwd a new top tab, split, or bottom-panel spawn inherits: the active
    /// center group's selected pane's context — a chat's live session cwd,
    /// a terminal's own override — falling back to the workspace root.
    /// Root is returned EXPLICITLY (not nil) so a root-context spawn stays
    /// at root even when the group's anchor session runs in a worktree.
    private func focusedSpawnCwd() -> String? {
        let workspace = store.workspace(for: session, project: project)
        return spawnCwd(for: activeLeafId, in: workspace)
    }

    private func spawnCwd(for leafId: UUID?, in workspace: Workspace) -> String? {
        let root = workspace.rootDirectory ?? project.folderURL.path
        guard let leafId else { return root }
        let selected = store.centerGroup(
            leafId: leafId, workspace: workspace, session: session, project: project
        ).state.selectedPane
        switch selected?.kind {
        case .chat:
            guard let chatId = selected?.chatSessionId,
                  let chat = environment.projectList.sessions.first(where: {
                      $0.serverId == session.serverId && $0.id == chatId
                  }),
                  let cwd = chat.cwd else { return root }
            return cwd
        case .terminal:
            return selected?.cwdOverride ?? root
        default:
            return root
        }
    }

    /// The run locations a New tab can open in: the project root plus the
    /// worktrees created by the workspace's chats (archived chats excluded
    /// — their worktrees aren't part of the working set).
    private func workspaceRunContexts() -> [WorkspaceRunContext] {
        WorkspaceRunContexts.contexts(
            workspace: store.workspace(for: session, project: project),
            project: project,
            sessions: environment.projectList.sessions.filter {
                $0.serverId == session.serverId
            }
        )
    }

    /// "New Chat" from a New tab page: creates the SESSION eagerly — a real
    /// chat from birth (sidebar row, archive-on-close, focus-follow), not a
    /// deferred draft — running in the picked context (project root or a
    /// sibling chat's worktree) with the default harness, then converts the
    /// placeholder in place.
    private func createChat(
        convertingPlaceholder paneId: UUID,
        in model: PaneGroupModel?,
        context: WorkspaceRunContext
    ) {
        guard let model else { return }
        let created = environment.projectList.newSession(
            in: project,
            title: "New Chat",
            worktreeName: context.worktreeName,
            cwd: context.path
        )
        model.convertNewTabPane(
            id: paneId, to: .chat,
            chatSessionId: created.id, name: created.title
        )
        // The pane's composer takes focus once it mounts; the responder
        // observer then walks the sidebar selection over to the new chat.
        sessionFocus.requestComposerFocus(forChat: created.id)
    }

    /// Removes an emptied split leaf. If it was its tab's final leaf, the
    /// whole top tab closes; the workspace's final tab is replaced by a New
    /// Tab page so the working surface itself never disappears.
    private func dissolveIfEmpty(leafId: UUID) {
        var workspace = store.workspace(for: session, project: project)
        let model = store.centerGroup(
            leafId: leafId, workspace: workspace, session: session, project: project
        )
        guard model.state.panes.isEmpty else { return }
        guard let tabIndex = workspace.centerTabs.firstIndex(where: {
            $0.root.group(id: leafId) != nil
        }) else { return }
        let oldLeafIds = workspace.centerTabs[tabIndex].root.allGroups.map(\.id)
        if let pruned = workspace.centerTabs[tabIndex].root.removingGroup(id: leafId) {
            workspace.centerTabs[tabIndex].root = pruned
            let oldIndex = oldLeafIds.firstIndex(of: leafId) ?? 0
            let survivors = pruned.allGroups.map(\.id)
            workspace.centerTabs[tabIndex].activeLeafId = survivors[
                min(oldIndex, survivors.count - 1)
            ]
            environment.workspaces.save(workspace)
            liveCenterTree = pruned
            store.evictCenterLeaf(workspaceId: workspace.id, leafId: leafId)
            workspaceRevision += 1
            activateLeaf(workspace.centerTabs[tabIndex].activeLeafId)
        } else {
            let closingTabId = workspace.centerTabs[tabIndex].id
            workspace.centerTabs.remove(at: tabIndex)
            if workspace.centerTabs.isEmpty {
                var state = PaneGroupState()
                _ = state.addNewTabPane(inheritedCwd: workspace.rootDirectory)
                let replacement = WorkspaceTab(root: .leaf(state))
                workspace.centerTabs = [replacement]
                workspace.selectedCenterTabId = replacement.id
            } else if workspace.selectedCenterTabId == closingTabId {
                workspace.selectedCenterTabId = workspace.centerTabs[
                    min(tabIndex, workspace.centerTabs.count - 1)
                ].id
            }
            environment.workspaces.save(workspace)
            store.evictCenterLeaf(workspaceId: workspace.id, leafId: leafId)
            workspaceRevision += 1
            liveCenterTree = workspace.centerTree
            activateLeaf(workspace.selectedCenterTab?.activeLeafId)
        }
    }

    /// Makes a leaf the active group (keyboard routing + hints).
    private func activateLeaf(_ leafId: UUID?) {
        activeLeafId = leafId
        if let leafId {
            var workspace = store.workspace(for: session, project: project)
            if let tabIndex = workspace.centerTabs.firstIndex(where: {
                $0.root.group(id: leafId) != nil
            }) {
                var changed = false
                if workspace.selectedCenterTabId != workspace.centerTabs[tabIndex].id {
                    workspace.selectedCenterTabId = workspace.centerTabs[tabIndex].id
                    liveCenterTree = workspace.centerTabs[tabIndex].root
                    changed = true
                }
                if workspace.centerTabs[tabIndex].activeLeafId != leafId {
                    workspace.centerTabs[tabIndex].activeLeafId = leafId
                    changed = true
                }
                if changed {
                    environment.workspaces.save(workspace)
                    workspaceRevision += 1
                }
            }
            sessionFocus.centerGroup = configuredCenterModel(leafId: leafId)
        }
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
    private func paneTitle(_ descriptor: PaneDescriptorState) -> String {
        descriptor.kind == .chat ? chatPaneTitle(descriptor) : descriptor.name
    }

    private func chatPaneTitle(_ descriptor: PaneDescriptorState) -> String {
        guard let id = descriptor.chatSessionId else { return descriptor.name }
        return environment.projectList.sessions.first {
            $0.serverId == session.serverId && $0.id == id
        }?.title ?? descriptor.name
    }

    private func firstSurvivingChatId() -> UUID? {
        let descriptors = store.workspace(for: session, project: project)
            .centerTabs.flatMap { tab in tab.root.allGroups }
            .flatMap { group in group.state.panes }
        return descriptors.first { descriptor in
            guard descriptor.kind == .chat,
                  let candidateId = descriptor.chatSessionId else { return false }
            return environment.projectList.sessions.contains { candidate in
                candidate.serverId == session.serverId
                    && candidate.id == candidateId
                    && !candidate.isArchived
            }
        }?.chatSessionId
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
                        },
                        paneFocus: focus,
                        hostWorkspaceId: store.workspace(for: session, project: project).id
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
                },
                hostWorkspaceId: store.workspace(for: session, project: project).id
            )
        }
    }

    /// The app-owned inspector column: hairline divider, resizable width.
    /// Sits below the native toolbar like the rest of the content.
    private var inspectorColumn: some View {
        SessionInspectorView(controller: controller, scratchpad: scratchpad)
            .frame(width: currentInspectorWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            // Extends under the toolbar (the themed surface ignores the safe
            // area) — intentional: the toolbar tints over the panel exactly
            // like it does over the native left sidebar. NO hairline on the
            // boundary for the same reason: the left sidebar separates by
            // background alone.
            .themedSurface(.sidebar)
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

    /// Every chat in the workspace with a live cached controller, routed
    /// session included. Controllers are never MINTED here (pure reads) —
    /// a chat whose controller isn't cached contributes nothing, and its
    /// persisted tabs survive untouched until it reconnects.
    private var workspaceChatControllers: [(chatId: UUID, controller: SessionController)] {
        let workspace = store.workspace(for: session, project: project)
        return workspace.chatSessionIds.compactMap { chatId in
            guard let chat = environment.projectList.sessions.first(where: {
                $0.serverId == session.serverId && $0.id == chatId
            }), let controller = store.activeController(for: chat) else { return nil }
            return (chatId, controller)
        }
    }

    /// Equatable digest of every chat's background-task state; onChange over
    /// this re-syncs when any task starts/ends or a snapshot arrives.
    private var backgroundTaskFingerprint: [String] {
        workspaceChatControllers.flatMap { chatId, controller -> [String] in
            let tasks = controller.backgroundTasks.compactMap { task in
                task.terminalKey.map { "\(chatId.uuidString)|\($0)|\(task.description)" }
            }
            return tasks + ["\(chatId.uuidString)|snapshot:\(controller.hasBackgroundTaskSnapshot)"]
        }
    }

    private func syncWorkspaceBackgroundTerminals() {
        let panel = store.paneGroup(for: session, project: project)
        for (chatId, controller) in workspaceChatControllers {
            panel.syncAgentTerminals(
                controller.backgroundTasks.compactMap { task in
                    task.terminalKey.map { (terminalKey: $0, name: task.description) }
                },
                owner: chatId,
                pruneEnded: controller.hasBackgroundTaskSnapshot
            )
        }
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
