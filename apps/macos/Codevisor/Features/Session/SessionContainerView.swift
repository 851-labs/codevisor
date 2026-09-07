import SwiftUI
import CodevisorCore
import CodevisorUI

/// Hosts an already-resolved session controller below the native toolbar
/// (which carries the editable tab name).
struct SessionContainerView: View {
  let session: ChatSession
  let project: Project
  let store: SessionStore
  /// Resolved synchronously with the navigation selection so the destination
  /// shell never waits for this view's asynchronous setup task to run.
  let controller: SessionController
  /// Fired when the user's focus lands in a DIFFERENT chat of this
  /// workspace (composer/transcript click, chat tab) — the sidebar
  /// selection follows, keeping its tab rows in sync with focus.
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
  /// tab commands (⌘T/⌘W/⌘1-9/⌘⌥←→) route here. Defaults to the
  /// primary chat leaf.
  @State var activeLeafId: UUID?
  /// Repository writes are intentionally non-observable. Structural tab
  /// changes bump this token so the sidebar and selected tree re-read truth.
  @State var workspaceRevision = 0
  /// Suppresses per-leaf dissolve while a whole top tab is closing.
  @State var closingCenterTabId: UUID?
  /// Presentation-only state for a locally inserted split. Its destination
  /// stays blank and inert until the opening geometry reaches its final size.
  @State var openingSplit: WorkspaceSplitOpening?
  /// The chat this container last published as focused, so `onDisappear`
  /// releases only its own focus (see the modifier in `body`).
  @State var publishedFocusCandidate: UUID?

  var body: some View {
    contentColumn
      .navigationTitle(tabTitle)
      .navigationSubtitle(workspaceSubtitle)
      .focusedSceneValue(\.browserPage, (sessionFocus.centerGroup?.selectedPane as? BrowserPane)?.model)
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
          reopenClosedPane: reopenClosedPane,
          previousTab: { selectRelativeCenterTab(offset: -1) },
          nextTab: { selectRelativeCenterTab(offset: 1) },
          previousSplit: { focusRelativeSplit(offset: -1) },
          nextSplit: { focusRelativeSplit(offset: 1) },
          split: splitActiveLeaf,
          focus: focusAdjacentLeaf
        )
      )
      // Keep background terminals synchronized across all of a workspace's
      // chats, including persisted terminal descriptors from older layouts.
      .environment(\.openMarkdownDocument, openMarkdownDocument)
      .onChange(of: backgroundTaskFingerprint, initial: true) { _, _ in
        syncWorkspaceBackgroundTerminals()
      }
      .onChange(of: environment.workspaceSync.revision, initial: true) { _, _ in
        synchronizeMountedPaneGroups()
      }
      // Every structural tab write bumps the local token; mirror it to the
      // store so the sidebar re-reads the repository.
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
        // A sidebar click names the exact tab to show (a terminal or
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

  /// Claims the sidebar's pending tab request if it targets this workspace.
  func takeCenterTabRequest(for workspaceId: UUID) -> CenterTabRequest? {
    guard let request = store.centerTabRequest, request.workspaceId == workspaceId else {
      return nil
    }
    store.centerTabRequest = nil
    return request
  }

  /// The selected sidebar tab's split layout.
  /// System themes reveal the native window backdrop. Custom themes paint
  /// one explicit page color behind every workspace pane.
  var contentColumn: some View {
    // WorkspaceRepository is intentionally non-observable. Server pane
    // reconciliation bumps this shared token so a tab created on another
    // device materializes in the mounted workspace immediately.
    let _ = (workspaceRevision, environment.workspaceSync.revision)
    let workspace = store.workspace(for: session, project: project)
    return VStack(spacing: 0) {
      SessionScreen(
        controller: controller,
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
    // The sidebar stays seamless under the toolbar; the content has a hairline.
    .overlay(alignment: .top) {
      theme.separator
        .frame(height: 1)
        .frame(maxWidth: .infinity)
    }
  }

  /// The sidebar carries the workspace name (it is the parent row),
  /// so the header names the selected TAB instead — the active split's
  /// pane, matching the row the sidebar highlights. Editing pins the tab's
  /// title through the workspace repository.
  var tabTitle: Binding<String> {
    Binding(
      get: {
        let workspace = store.workspace(for: session, project: project)
        guard let tab = workspace.selectedCenterTab else { return workspace.name }
        if let customTitle = tab.customTitle { return customTitle }
        guard let descriptor = headerDescriptor(in: tab) else { return "New Tab" }
        return paneTitle(descriptor)
      },
      set: { newValue in
        let workspace = store.workspace(for: session, project: project)
        renameCenterTab(workspace.selectedCenterTabId, to: newValue)
      }
    )
  }

  /// The context the title no longer carries: where this tab runs. Ordered
  /// widest-to-narrowest and de-duplicated, since a workspace is commonly
  /// named after its worktree or project.
  var workspaceSubtitle: String {
    let workspace = store.workspace(for: session, project: project)
    let candidates: [String?] = [
      workspace.name,
      project.name,
      workspace.worktreeName,
      environment.machines.fleetMachineName(for: session.serverId),
    ]
    var parts: [String] = []
    for candidate in candidates {
      guard let candidate, !candidate.isEmpty, !parts.contains(candidate) else { continue }
      parts.append(candidate)
    }
    return parts.joined(separator: " · ")
  }

  /// The pane the header speaks for: the LIVE active leaf when it belongs
  /// to this tab (the sidebar can move it), else the tab's persisted one.
  private func headerDescriptor(in tab: WorkspaceTab) -> PaneDescriptorState? {
    let leafId = activeLeafId.flatMap { tab.root.group(id: $0) != nil ? $0 : nil } ?? tab.activeLeafId
    return configuredCenterModel(leafId: leafId).state.selectedPane
      ?? tab.root.group(id: leafId)?.selectedPane
      ?? tab.root.allGroups.first?.state.selectedPane
  }

}
