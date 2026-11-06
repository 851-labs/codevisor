import SwiftUI
import CodevisorCore
import CodevisorUI
import SimulatorPane

struct SessionContainerView: View {
  enum Mount {
    case chat(ChatSession, Workspace)
    case workspace(Workspace)
  }

  let mount: Mount
  let project: Project
  let store: SessionStore

  var session: ChatSession? {
    if case let .chat(session, _) = mount { return session }
    return nil
  }
  var onFocusedChatChanged: ((UUID) -> Void)? = nil
  @Environment(AppEnvironment.self) var environment
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.quickLook) var quickLook
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) var botsEnabled
  @State var splitDragCoordinator = WorkspaceSplitDragCoordinator()
  @State var sessionFocus = TerminalFocusController()

  @State private var centerTreePreview: WorkspaceTreePreview?

  var liveCenterTree: SplitNode? {
    get { centerTreePreview?.tree(in: selectedWorkspace) }
    nonmutating set {
      centerTreePreview = newValue.map {
        WorkspaceTreePreview(workspace: selectedWorkspace, tree: $0)
      }
    }
  }

  var mountIdentity: UUID {
    switch mount {
    case let .chat(session, _): return session.id
    case let .workspace(snapshot): return snapshot.id
    }
  }

  var mountedWorkspace: Workspace {
    switch mount {
    case let .chat(_, workspace), let .workspace(workspace): workspace
    }
  }

  var workspaceEntry: WorkspaceEntry {
    environment.navigationStore.workspaceEntries.entry(mountedWorkspace.id)
  }

  var selectedWorkspace: Workspace {
    workspaceEntry.workspace ?? mountedWorkspace
  }

  var activeLeafId: UUID? {
    selectedWorkspace.selectedCenterTab?.resolvedActiveLeafId(preferred: nil)
  }
  @State var closingCenterTabId: UUID?
  @State var openingSplit: WorkspaceSplitOpening?
  @State var focusSourceId = UUID()
  @State var isVisible = false

  var body: some View {
    mounted(in: selectedWorkspace)
      .environment(\.pluginAppPresenter, pluginAppPresenter)
  }

  private func mounted(in workspace: Workspace) -> some View {
    contentColumn
      .background {
        ActiveWorkspaceOnly { sceneChrome }
      }
      .environment(\.openFileDocument, OpenFileDocumentAction { openFileDocument($0, rendered: $1) })
      .environment(
        \.openSubagent,
        OpenSubagentAction { parentId, toolCallId, title, placement in
          openSubagent(parentSessionId: parentId, toolCallId: toolCallId, title: title, placement: placement)
        }
      )
      .onChange(of: workspaceEntry.generation, initial: true) { _, _ in
        synchronizeMountedPaneGroups()
      }
      .modifier(
        CenterTabRequests(store: store, workspaceId: workspace.id, onClose: closeCenterTab)
      )
      .modifier(ChildAgentSplitRequests(store: store, workspaceId: workspace.id, onOpen: openChildAgent))
      .onChange(of: store.inspectorOpenRequest) { _, request in
        guard let request, request.workspaceId == workspace.id else { return }
        store.inspectorOpenRequest = nil
        openInspectorDestination(request.destination)
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
      .onChange(of: focusedChatCandidate, initial: true) { _, candidate in
        publishFocusedChat(candidate)
      }
      .onWorkspaceVisibilityChange(show: showWorkspace, hide: hideWorkspace)
      .task(id: mountIdentity) { wireMount() }
  }

  private func wireMount() {
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
    sessionFocus.onChatComposerFocused = { chatId in
      let workspace = selectedWorkspace
      guard isVisible,
        store.navigationWorkspaceId == workspace.id,
        let leaf = workspace.centerTree.groupId(containingChat: chatId)
      else { return }
      if leaf != activeLeafId {
        activateLeaf(leaf)
      }
      if chatId != session?.id {
        onFocusedChatChanged?(chatId)
      }
    }
    if let session {
      store.markOpened(session.id, serverId: session.serverId)
    }
  }

  private func showWorkspace() {
    isVisible = true
    store.navigationWorkspaceId = selectedWorkspace.id
    sessionFocus.navigationRevision = { store.navigationRevision }
    sessionFocus.canFocusChat = { chatId in
      isVisible && store.navigationWorkspaceId == selectedWorkspace.id
        && activePaneDescriptor?.chatSessionId == chatId
    }
    setSelectedPanesVisible(true)
    publishFocusedChat(focusedChatCandidate)
    focusSelectedCenterPane()
  }

  private func hideWorkspace() {
    isVisible = false
    store.clearFocusedChat(sourceId: focusSourceId)
    setSelectedPanesVisible(false)
  }

  private func setSelectedPanesVisible(_ visible: Bool) {
    let workspace = selectedWorkspace
    for leaf in workspace.selectedCenterTab?.root.allGroups ?? [] {
      let key = SessionStore.CenterLeafKey(workspaceId: workspace.id, groupId: leaf.id)
      store.centerLeafGroups[key]?.selectedPane?.visibilityChanged(visible)
    }
  }

  private func publishFocusedChat(_ candidate: UUID?) {
    let workspace = selectedWorkspace
    store.setFocusedChat(
      candidate, serverId: workspace.serverId, sourceId: focusSourceId,
      workspaceId: workspace.id, isVisible: isVisible
    )
  }

  var contentColumn: some View {
    let workspace = selectedWorkspace
    let chatLeaf = singlePaneChatLeaf(in: workspace)
    return VStack(spacing: 0) {
      SessionScreen(
        centerGroup: chatLeaf.map { configuredCenterModel(leafId: $0.id) } ?? activeCenterModel(in: workspace),
        focus: sessionFocus,
        onWorkspaceCommand: handleWorkspaceCommand,
        centerTree: chatLeaf.map { .group(id: $0.id, state: $0.state) } ?? liveCenterTree ?? workspace.centerTree,
        primaryLeafId: session.flatMap { workspace.centerTree.groupId(containingChat: $0.id) },
        activeLeafId: chatLeaf?.id ?? activeLeafId,
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
      .environment(\.usesSlimComposer, isSinglePane)
    }
    .overlay(alignment: .top) {
      if !isSinglePane {
        Color.separatorColor
          .frame(height: 1)
          .frame(maxWidth: .infinity)
      }
    }
  }
}
