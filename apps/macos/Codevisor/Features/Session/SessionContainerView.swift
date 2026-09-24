import SwiftUI
import CodevisorCore
import CodevisorUI

/// Hosts one workspace below the native toolbar (which follows the active
/// pane): either a resolved chat session and its controller, or the workspace
/// alone when it has never hosted a chat.
struct SessionContainerView: View {
  /// What this container is mounted on. A workspace owns its layout, server
  /// identity and pane persistence with or without a chat; the chat case adds
  /// the anchor session and its controller. There is no third state, so no
  /// call site has to invent a session to show a workspace.
  enum Mount {
    /// Resolved synchronously with the navigation selection so the destination
    /// shell never waits for this view's asynchronous setup task to run. The
    /// workspace is the one the route chose for the chat (created there for
    /// a brand-new chat), as a snapshot like `.workspace`.
    case chat(ChatSession, SessionController, Workspace)
    /// The mount-time snapshot; the live record is the workspace's entry.
    case workspace(Workspace)
  }

  let mount: Mount
  let project: Project
  let store: SessionStore

  /// The anchor chat, when there is one. Chat focus, read and open reporting,
  /// and anything keyed by a session identity, all go through this.
  var session: ChatSession? {
    if case let .chat(session, _, _) = mount { return session }
    return nil
  }
  var controller: SessionController? {
    if case let .chat(_, controller, _) = mount { return controller }
    return nil
  }
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

  /// Divider previews are valid only for the persisted tab they started
  /// from. A navigation or remote layout change takes effect immediately.
  @State private var centerTreePreview: WorkspaceTreePreview?

  var liveCenterTree: SplitNode? {
    get { centerTreePreview?.tree(in: selectedWorkspace) }
    nonmutating set {
      centerTreePreview = newValue.map {
        WorkspaceTreePreview(workspace: selectedWorkspace, tree: $0)
      }
    }
  }

  /// Re-runs the container's setup task when the mounted thing changes.
  var mountIdentity: UUID {
    switch mount {
    case let .chat(session, _, _): return session.id
    case let .workspace(snapshot): return snapshot.id
    }
  }

  /// The workspace as the route chose it. Its id never changes for this
  /// container (the route remounts on a different workspace).
  var mountedWorkspace: Workspace {
    switch mount {
    case let .chat(_, _, workspace), let .workspace(workspace): workspace
    }
  }

  /// This workspace's observable entry: reading it re-renders the container
  /// when -- and only when -- this workspace changes.
  var workspaceEntry: WorkspaceEntry {
    environment.navigationStore.workspaceEntries.entry(mountedWorkspace.id)
  }

  /// The live record, an O(1) read. The snapshot covers the window between
  /// a remote deletion and the selection moving away.
  var selectedWorkspace: Workspace {
    workspaceEntry.workspace ?? mountedWorkspace
  }

  var activeLeafId: UUID? {
    selectedWorkspace.selectedCenterTab?.resolvedActiveLeafId(preferred: nil)
  }
  /// Suppresses per-leaf dissolve while a whole top tab is closing.
  @State var closingCenterTabId: UUID?
  /// Presentation-only state for a locally inserted split. Its destination
  /// stays blank and inert until the opening geometry reaches its final size.
  @State var openingSplit: WorkspaceSplitOpening?
  /// Identifies this mounted container independently of its cached chat.
  @State var focusSourceId = UUID()
  @State var isVisible = false

  var body: some View {
    mounted(in: selectedWorkspace)
  }

  /// The container around one read of the workspace.
  private func mounted(in workspace: Workspace) -> some View {
    titledContentColumn
      .navigationSubtitle(activePaneSubtitle)
      .toolbar(removing: paneControlsReplaceTitle ? .title : nil)
      .toolbar {
        if let browser = activeBrowserModel {
          ChromiumBrowserNavigationControls(model: browser)
          ChromiumBrowserAddressToolbarItem(model: browser)
        } else if let pane = activeScreenSharingPane, let store = pane.store {
          ScreenSharingToolbar(store: store)
        } else if let model = activeFileModel {
          FilePaneToolbar(model: model, onNewTab: addCenterTab)
        }
      }
      .focusedSceneValue(\.browserPage, activeBrowserModel)
      .focusedSceneValue(\.filePane, activeFileModel)
      .focusedSceneValue(
        \.workspaceLayoutActions,
        WorkspaceLayoutActions(
          workspaceId: workspace.id,
          newTab: addCenterTab,
          closeSplit: closeActiveLeaf,
          closeTab: {
            let workspace = selectedWorkspace
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
      .environment(\.openFileDocument, openFileDocument)
      .onChange(of: backgroundTaskFingerprint, initial: true) { _, _ in
        syncWorkspaceBackgroundTerminals()
      }
      // Any change to this workspace -- local or from another device --
      // reaches mounted pane models that hold live views and focus.
      .onChange(of: workspaceEntry.generation, initial: true) { _, _ in
        synchronizeMountedPaneGroups()
      }
      // Structural commands may arrive as this workspace is mounting.
      // Navigation itself has already committed before view construction.
      .onChange(of: store.centerTabRequest, initial: true) { _, request in
        guard let request, store.centerTabRequest == request,
          request.workspaceId == workspace.id
        else { return }
        store.centerTabRequest = nil
        performCenterTabRequest(request)
      }
      .onChange(of: activePaneDescriptor?.id, initial: true) { _, _ in
        focusSelectedCenterPane()
      }
      .onChange(of: workspace.selectedCenterTabId) { _, _ in
        openingSplit = nil
      }
      .onChange(of: activeLeafId) { _, leafId in
        if let openingSplit, openingSplit.leafId != leafId { self.openingSplit = nil }
      }
      .onAppear {
        isVisible = true
        store.navigationWorkspaceId = selectedWorkspace.id
        sessionFocus.navigationRevision = { store.navigationRevision }
        sessionFocus.canFocusChat = { chatId in
          isVisible && store.navigationWorkspaceId == selectedWorkspace.id
            && activePaneDescriptor?.chatSessionId == chatId
        }
        focusSelectedCenterPane()
      }
      // Read = focus: publish the chat pane facing the user in this
      // window (selected pane of the active split leaf). The store
      // combines it with window-key state and feeds the app-wide
      // attention coordinator, which marks the focused chat read.
      .onChange(of: focusedChatCandidate, initial: true) { _, candidate in
        let workspace = selectedWorkspace
        store.setFocusedChat(
          candidate, serverId: workspace.serverId, sourceId: focusSourceId,
          workspaceId: workspace.id, isVisible: isVisible
        )
      }
      // The incoming container can publish before this one disappears.
      .onDisappear {
        isVisible = false
        store.clearFocusedChat(sourceId: focusSourceId)
      }
      .task(id: mountIdentity) {
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
        // Upward focus feedback: clicking into any chat's composer
        // makes its group the active one (terminals do the same through
        // their surface responder callbacks) — and the sidebar's chat
        // selection follows the focused chat.
        sessionFocus.onChatComposerFocused = { chatId in
          let workspace = selectedWorkspace
          guard isVisible,
            store.navigationWorkspaceId == workspace.id,
            let leaf = workspace.centerTree.groupId(containingChat: chatId)
          else { return }
          if leaf != activeLeafId {
            activateLeaf(leaf)
          }
          rememberWorkspaceDefaults(from: chatId)
          if chatId != session?.id {
            onFocusedChatChanged?(chatId)
          }
        }
        // Opening is a chat event: a workspace mount has nothing to mark read.
        if let session {
          store.markOpened(session.id, serverId: session.serverId)
        }
      }
  }

  /// The selected sidebar tab's split layout.
  /// System themes reveal the native window backdrop. Custom themes paint
  /// one explicit page color behind every workspace pane.
  var contentColumn: some View {
    // Observes this workspace's entry, so a tab created on another device
    // materializes in the mounted workspace immediately.
    let workspace = selectedWorkspace
    return VStack(spacing: 0) {
      SessionScreen(
        controller: controller,
        centerGroup: activeCenterModel(in: workspace),
        focus: sessionFocus,
        onWorkspaceCommand: handleWorkspaceCommand,
        centerTree: liveCenterTree ?? workspace.centerTree,
        primaryLeafId: session.flatMap { workspace.centerTree.groupId(containingChat: $0.id) },
        activeLeafId: activeLeafId,
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
}
