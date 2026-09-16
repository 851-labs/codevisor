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
    /// shell never waits for this view's asynchronous setup task to run.
    case chat(ChatSession, SessionController)
    /// The mount-time snapshot; the live record is re-read from the repository.
    case workspace(Workspace)
  }

  let mount: Mount
  let project: Project
  let store: SessionStore

  /// The anchor chat, when there is one. Chat focus, read and open reporting,
  /// and anything keyed by a session identity, all go through this.
  var session: ChatSession? {
    if case let .chat(session, _) = mount { return session }
    return nil
  }
  var controller: SessionController? {
    if case let .chat(_, controller) = mount { return controller }
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
    case let .chat(session, _): return session.id
    case let .workspace(snapshot): return snapshot.id
    }
  }

  var selectedWorkspace: Workspace {
    let _ = (workspaceRevision, store.workspaceLayoutRevision, environment.workspaceSync.revision)
    switch mount {
    case let .chat(session, _):
      return store.workspace(for: session, project: project)
    case let .workspace(snapshot):
      // The repository owns the live record; the snapshot covers the window
      // between a remote deletion and the selection moving away.
      return environment.workspaces.workspace(id: snapshot.id) ?? snapshot
    }
  }

  var activeLeafId: UUID? {
    selectedWorkspace.selectedCenterTab?.resolvedActiveLeafId(preferred: nil)
  }
  /// Repository writes are intentionally non-observable. Structural tab
  /// changes bump this token so the sidebar and selected tree re-read truth.
  @State var workspaceRevision = 0
  /// Suppresses per-leaf dissolve while a whole top tab is closing.
  @State var closingCenterTabId: UUID?
  /// Presentation-only state for a locally inserted split. Its destination
  /// stays blank and inert until the opening geometry reaches its final size.
  @State var openingSplit: WorkspaceSplitOpening?
  /// Identifies this mounted container independently of its cached chat.
  @State var focusSourceId = UUID()
  @State var isVisible = false

  var body: some View {
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
          workspaceId: selectedWorkspace.id,
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
      .onChange(of: environment.workspaceSync.revision, initial: true) { _, _ in
        synchronizeMountedPaneGroups()
      }
      // Every structural tab write bumps the local token; mirror it to the
      // store so the sidebar re-reads the repository.
      .onChange(of: workspaceRevision) { _, _ in
        store.workspaceLayoutRevision += 1
      }
      // Structural commands may arrive as this workspace is mounting.
      // Navigation itself has already committed before view construction.
      .onChange(of: store.centerTabRequest, initial: true) { _, request in
        guard let request, store.centerTabRequest == request,
          request.workspaceId == selectedWorkspace.id
        else { return }
        store.centerTabRequest = nil
        performCenterTabRequest(request)
      }
      .onChange(of: activePaneDescriptor?.id, initial: true) { _, _ in
        focusSelectedCenterPane()
      }
      .onChange(of: selectedWorkspace.selectedCenterTabId) { _, _ in
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
        store.setFocusedChat(
          candidate, serverId: selectedWorkspace.serverId, sourceId: focusSourceId,
          workspaceId: selectedWorkspace.id, isVisible: isVisible
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
          guard isVisible,
            store.navigationWorkspaceId == selectedWorkspace.id,
            selectedWorkspace.centerTree.groupId(containingChat: chatId) != nil
          else { return }
          if let leaf = selectedWorkspace.centerTree.groupId(containingChat: chatId),
            leaf != activeLeafId
          {
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
    // WorkspaceRepository is intentionally non-observable. Server pane
    // reconciliation bumps this shared token so a tab created on another
    // device materializes in the mounted workspace immediately.
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
