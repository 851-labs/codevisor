import SwiftUI
import CodevisorCore
import CodevisorUI

/// Hosts an already-resolved session controller below the native toolbar
/// (which carries the editable workspace name).
struct SessionContainerView: View {
  let session: ChatSession
  let project: Project
  let store: SessionStore
  /// Resolved synchronously with the navigation selection so the destination
  /// shell never waits for this view's asynchronous setup task to run.
  let controller: SessionController
  /// Fired when the user's focus lands in a DIFFERENT chat of this
  /// workspace (composer/transcript click, chat tab) — the sidebar
  /// selection follows, keeping the by-chat list in sync with focus.
  /// Non-chat focus (terminals) fires nothing: the last chat stays.
  var onFocusedChatChanged: ((UUID) -> Void)? = nil
  @Environment(AppEnvironment.self) var environment
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.theme) var theme
  /// Global geometry + pointer state for rearranging split leaves inside
  /// the selected top tab by dragging their headers.
  @State var splitDragCoordinator = WorkspaceSplitDragCoordinator()
  /// The session's focus coordinator (composer ⇄ terminals). Owned here so
  /// every center leaf's chat content — any group can host chats — wires
  /// against the same instance.
  @State var sessionFocus = TerminalFocusController()

  /// The workspace's LIVE center tree (the repository isn't observable):
  /// seeded per session, updated by divider drags so the layout re-renders
  /// with what was just persisted.
  @State var liveCenterTree: SplitNode?

  /// The ACTIVE center group (the one the user last acted in): keyboard
  /// tab commands (⌘T/⌘W/⌘1-9/⌘⌥←→) route here and its bar shows the
  /// ⌘-hints. Defaults to the primary (chat) leaf.
  @State var activeLeafId: UUID?
  /// Repository writes are intentionally non-observable. Structural tab
  /// changes bump this token so the strip and selected tree re-read truth.
  @State var workspaceRevision = 0
  /// Suppresses per-leaf dissolve while a whole top tab is closing.
  @State var closingCenterTabId: UUID?
  /// Presentation-only state for a locally inserted split. Its destination
  /// stays blank and inert until the opening geometry reaches its final size.
  @State var openingSplit: WorkspaceSplitOpening?
  /// The chat this container last published as focused, so `onDisappear`
  /// releases only its own focus (see the modifier in `body`).
  @State var publishedFocusCandidate: UUID?
  @ClientPreference("sidebar.organization", default: SidebarOrganization.compact.rawValue)
  private var sidebarOrganizationRaw

  /// Nous: the sidebar lists this workspace's tabs, so the in-content
  /// strip stays hidden and sidebar clicks drive tab selection here.
  var isNousMode: Bool {
    SidebarOrganization(rawValue: sidebarOrganizationRaw) == .nous
  }

  var body: some View {
    contentColumn
      // The NATIVE toolbar names the workspace — editable inline, like a
      // document title. Edits pin the name (it stops tracking the primary
      // chat's title).
      .navigationTitle(workspaceName)
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
      .onChange(of: environment.workspaceSync.revision, initial: true) { _, _ in
        synchronizeMountedPaneGroups()
      }
      // Every structural tab write bumps the local token; mirror it to the
      // store so the Nous sidebar re-reads the repository.
      .onChange(of: workspaceRevision) { _, _ in
        store.workspaceLayoutRevision += 1
      }
      // A sidebar tab click while this workspace is already mounted.
      // Requests that arrive with a route change are consumed by the
      // routing task below instead; re-checking the store avoids acting
      // twice when both observe the same request.
      .onChange(of: store.centerTabRequest) { _, request in
        guard let request, store.centerTabRequest == request,
          request.workspaceId == store.workspace(for: session, project: project).id
        else { return }
        store.centerTabRequest = nil
        performCenterTabRequest(request)
      }
      // Read = focus: publish the chat pane facing the user in this
      // window (selected pane of the active split leaf). The store
      // combines it with window-key state and feeds the app-wide
      // attention coordinator, which marks the focused chat read.
      .onChange(of: focusedChatCandidate, initial: true) { _, candidate in
        publishedFocusCandidate = candidate
        store.setFocusedChat(candidate, serverId: session.serverId)
      }
      // Release only the focus this container published. Navigating to
      // another workspace mounts the new container (which publishes its
      // chat) BEFORE this one disappears; an unconditional clear here
      // would erase the new focus and leave that chat unread while the
      // user is looking straight at it.
      .onDisappear {
        if let candidate = publishedFocusCandidate {
          store.clearFocusedChat(ifCurrent: candidate)
        }
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
        let liveRoutedSession =
          environment.projectList.sessions.first {
            $0.serverId == session.serverId && $0.id == session.id
          } ?? session
        // A chat removed by closing its old pane keeps its grow-only
        // workspace index. If it is later restored/unarchived, route it
        // back into that workspace as a fresh single-chat top tab.
        if !liveRoutedSession.isArchived,
          routedWorkspace.tabId(containingChat: session.id) == nil
        {
          let tab = WorkspaceTab(root: .leaf(.centerInitial(sessionId: session.id)))
          routedWorkspace.centerTabs.append(tab)
          routedWorkspace.selectedCenterTabId = tab.id
          environment.workspaces.save(routedWorkspace)
          workspaceRevision += 1
          liveCenterTree = tab.root
        }
        // A Nous sidebar click names the exact tab to show (a terminal or
        // New Tab row has no chat of its own to route by); otherwise the
        // routed chat's tab wins.
        let pendingRequest = takeCenterTabRequest(for: routedWorkspace.id)
        var requestedTabId: UUID?
        var requestedLeafId: UUID?
        switch pendingRequest?.action {
        case let .select(tabId)? where routedWorkspace.centerTabs.contains(where: { $0.id == tabId }):
          requestedTabId = tabId
        case let .selectLeaf(leafId)?:
          if let tab = routedWorkspace.centerTabs.first(where: { $0.root.group(id: leafId) != nil }) {
            requestedTabId = tab.id
            requestedLeafId = leafId
          }
        default:
          break
        }
        let routedTabId = requestedTabId ?? routedWorkspace.tabId(containingChat: session.id)
        if let routedTabId, routedWorkspace.selectedCenterTabId != routedTabId {
          routedWorkspace.selectedCenterTabId = routedTabId
          environment.workspaces.save(routedWorkspace)
          workspaceRevision += 1
          liveCenterTree = routedWorkspace.centerTree
        }
        if requestedTabId != nil,
          let requestedTab = routedWorkspace.selectedCenterTab,
          let leafId = requestedLeafId
            ?? (requestedTab.root.groupId(containingChat: session.id) == nil
              ? requestedTab.activeLeafId : nil)
        {
          // A named pane, or a tab holding no routed chat: that leaf takes
          // over, exactly as clicking its header would arrange it.
          let model = configuredCenterModel(leafId: leafId)
          activateLeaf(leafId)
          model.selectedPane?.visibilityChanged(true)
          DispatchQueue.main.async { model.focusSelectedPane() }
        } else if let primaryLeaf = routedWorkspace.centerTree.groupId(containingChat: session.id) {
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
        switch pendingRequest?.action {
        case .new?: addCenterTab()
        case let .close(tabId)?: closeCenterTab(tabId)
        case let .closeLeaf(leafId)?: closeLeaf(leafId)
        default: break
        }
        // Upward focus feedback: clicking into any chat's composer
        // makes its group the active one (terminals do the same through
        // their surface responder callbacks) — and the sidebar's chat
        // selection follows the focused chat.
        sessionFocus.onChatComposerFocused = { chatId in
          if let leaf = store.workspace(for: session, project: project)
            .centerTree.groupId(containingChat: chatId),
            leaf != activeLeafId
          {
            activateLeaf(leaf)
          }
          rememberWorkspaceDefaults(from: chatId)
          if chatId != session.id {
            onFocusedChatChanged?(chatId)
          }
        }
        store.markOpened(session.id, serverId: session.serverId)
        controller.rememberCurrentComposerConfiguration()
        // UNSTARTED chats (eagerly created records with no first message
        // yet) must not connect here: connecting launches an agent with
        // the DEFAULT harness, silently making the choice their new-chat
        // composer still offers. Their first send owns the connection.
        guard session.hasAgentSession || controller.isConnected else { return }
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

  /// Whether the center tab strip is on screen. Read by `contentColumn` to
  /// decide whether the top hairline is still needed. Nous moves the tabs
  /// into the sidebar, so the strip never shows there.
  var isShowingCenterTabBar: Bool {
    !isNousMode && store.workspace(for: session, project: project).centerTabs.count > 1
  }

  /// Claims the sidebar's pending tab request if it targets this workspace.
  func takeCenterTabRequest(for workspaceId: UUID) -> CenterTabRequest? {
    guard let request = store.centerTabRequest, request.workspaceId == workspaceId else {
      return nil
    }
    store.centerTabRequest = nil
    return request
  }

  /// The session content: a browser-style tab bar above the selected
  /// tab's split layout.
  /// System themes reveal the native window backdrop. Custom themes paint
  /// one explicit page color behind every workspace pane.
  var contentColumn: some View {
    // WorkspaceRepository is intentionally non-observable. Server pane
    // reconciliation bumps this shared token so a tab created on another
    // device materializes in the mounted macOS strip immediately.
    let _ = (workspaceRevision, environment.workspaceSync.revision)
    let workspace = store.workspace(for: session, project: project)
    let bottomGroup = store.paneGroup(for: session, project: project)
    return VStack(spacing: 0) {
      if isShowingCenterTabBar {
        WorkspaceTabBar(
          tabs: workspace.centerTabs,
          selectedTabId: workspace.selectedCenterTabId,
          title: workspaceTabTitle,
          descriptor: workspaceTabDescriptor,
          pluginIconClient: environment.machines.client(for: session.serverId),
          pluginIconCacheNamespace: session.serverId,
          showsShortcutHints: !bottomGroup.hasFocusedPane,
          onSelect: selectCenterTab,
          onClose: closeCenterTab,
          onMove: moveCenterTab,
          onRename: renameCenterTab,
          onNew: addCenterTab
        )
      }
      SessionScreen(
        controller: controller,
        paneGroup: bottomGroup,
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
        openingSplit: openingSplit,
        onSplitOpeningFinished: finishSplitOpening,
        onCenterTreeChanged: { tree in
          liveCenterTree = tree
          saveSelectedTree(tree, workspaceId: workspace.id)
        },
        onCenterTreeLiveChanged: { tree in liveCenterTree = tree }
      )
    }
    .background(theme.contentBackground)
    // The hairline under the top bar: drawn by the CENTER panel's top
    // edge (the sidebar stays seamless under the toolbar). Suppressed
    // when the tab bar is showing — the tab strip already has its own
    // bottom divider, and two rules 28pt apart box the tabs in.
    .overlay(alignment: .top) {
      if !isShowingCenterTabBar {
        theme.separator
          .frame(height: 1)
          .frame(maxWidth: .infinity)
      }
    }
  }

  /// The workspace's name as an editable window title: edits save through
  /// the repository with `hasCustomName` pinned so later worktree creation
  /// does not replace it.
  var workspaceName: Binding<String> {
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

}
