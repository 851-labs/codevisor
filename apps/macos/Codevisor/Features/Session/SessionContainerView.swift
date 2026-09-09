import SwiftUI
import CodevisorCore
import CodevisorUI

/// Hosts an already-resolved session controller below the native toolbar
/// (which follows the active pane).
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

  var selectedWorkspace: Workspace {
    let _ = (workspaceRevision, store.workspaceLayoutRevision, environment.workspaceSync.revision)
    return store.workspace(for: session, project: project)
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
  /// The chat this container last published as focused, so `onDisappear`
  /// releases only its own focus (see the modifier in `body`).
  @State var publishedFocusCandidate: UUID?
  @State var isVisible = false

  var body: some View {
    contentColumn
      .navigationTitle(activePaneTitle)
      .navigationSubtitle(activePaneDescriptor?.kind == .chat ? activePaneSubtitle : "")
      .toolbar(removing: activePaneDescriptor?.kind == .browser ? .title : nil)
      .toolbar {
        if let browser = activeBrowserModel {
          ChromiumBrowserNavigationControls(model: browser)
          ToolbarItem(placement: .principal) {
            ChromiumBrowserToolbar(model: browser)
              .id(browser.paneId)
          }
          .sharedBackgroundVisibility(.hidden)
        }
      }
      .focusedSceneValue(\.browserPage, activeBrowserModel)
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
      // Structural commands may arrive as this workspace is mounting.
      // Navigation itself has already committed before view construction.
      .onChange(of: store.centerTabRequest, initial: true) { _, request in
        guard let request, store.centerTabRequest == request,
          request.workspaceId == store.workspace(for: session, project: project).id
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
        publishedFocusCandidate = candidate
        store.setFocusedChat(candidate, serverId: session.serverId)
      }
      // Release only the focus this container published. Navigating to
      // another workspace mounts the new container (which publishes its
      // chat) BEFORE this one disappears; an unconditional clear here
      // would erase the new focus and leave that chat unread while the
      // user is looking straight at it.
      .onDisappear {
        isVisible = false
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
        // Upward focus feedback: clicking into any chat's composer
        // makes its group the active one (terminals do the same through
        // their surface responder callbacks) — and the sidebar's chat
        // selection follows the focused chat.
        sessionFocus.onChatComposerFocused = { chatId in
          guard isVisible,
            store.navigationWorkspaceId == selectedWorkspace.id,
            store.workspace(for: session, project: project).centerTree.groupId(containingChat: chatId) != nil
          else { return }
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
        primaryLeafId: workspace.centerTree.groupId(containingChat: session.id),
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
