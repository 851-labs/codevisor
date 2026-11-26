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
  @Environment(\.fileLightbox) var fileLightbox
  @Environment(WorkspacePageModel.self) var page: WorkspacePageModel?
  @Environment(\.hidesWorkspaceTitle) var hidesWorkspaceTitle
  @State var splitDragCoordinator = WorkspaceSplitDragCoordinator()
  @State var sessionFocus = TerminalFocusController()
  @State var floatingFocusHandoff = PaneFocusHandoff()

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
  @State private var shown = WorkspaceShownFlag()

  var isVisible: Bool {
    get { shown.isShown }
    nonmutating set { shown.isShown = newValue }
  }

  var body: some View {
    mounted(in: selectedWorkspace)
      .environment(\.pluginAppPresenter, pluginAppPresenter)
  }

  private func mounted(in workspace: Workspace) -> some View {
    contentColumn
      .background {
        WorkspaceChromeReporter(chrome: { chrome }, page: page)
        FocusedChatReporter(candidate: { focusedChatCandidate }, report: publishFocusedChat)
      }
      .environment(
        \.openFileDocument,
        OpenFileDocumentAction(identity: handlerIdentity) { openFileDocument($0, rendered: $1) }
      )
      .environment(\.fileOpener, fileOpener)
      .environment(
        \.openSubagent,
        OpenSubagentAction(identity: handlerIdentity) { parentId, toolCallId, title, placement in
          openSubagent(parentSessionId: parentId, toolCallId: toolCallId, title: title, placement: placement)
        }
      )
      .onChange(of: workspaceEntry.generation, initial: true) { _, _ in
        synchronizeMountedPaneGroups()
      }
      .onChange(of: floatingLayout, initial: true) { _, _ in
        dockStaleFloatingPanes()
      }
      .onChange(of: leavesCoveredByPage) { before, after in
        showPage(covering: after, uncovering: before.subtracting(after))
      }
      .modifier(BotPageUpkeep(workspace: workspace, store: store, focusPage: focusVisiblePage))
      .modifier(
        CenterTabRequests(store: store, workspaceId: workspace.id, onClose: closeCenterTab)
      )
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
        bringFloatingPaneToFront(leafId)
      }
      .onWorkspaceVisibilityChange(show: showWorkspace, hide: hideWorkspace)
      .onChange(of: mountedWorkspace.id) { previous, _ in showWorkspace(replacing: previous) }
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
        && presentedChatId(in: activePaneDescriptor) == chatId
    }
    setSelectedPanesVisible(true)
    publishFocusedChat(focusedChatCandidate)
    focusSelectedCenterPane()
  }

  private func showWorkspace(replacing previous: UUID) {
    closingCenterTabId = nil
    openingSplit = nil
    wireMount()
    synchronizeMountedPaneGroups()
    guard isVisible else { return }

    for (key, model) in store.centerLeafGroups where key.workspaceId == previous {
      model.selectedPane?.visibilityChanged(false)
    }
    showWorkspace()
  }

  private func hideWorkspace() {
    isVisible = false
    store.clearFocusedChat(sourceId: focusSourceId)
    setSelectedPanesVisible(false)
  }

  private func setSelectedPanesVisible(_ visible: Bool) {
    let workspace = selectedWorkspace
    let covered = leavesCoveredByPage
    for leaf in workspace.selectedCenterTab?.root.allGroups ?? [] where !covered.contains(leaf.id) {
      let key = SessionStore.CenterLeafKey(workspaceId: workspace.id, groupId: leaf.id)
      store.centerLeafGroups[key]?.selectedPane?.visibilityChanged(visible)
    }
  }

  private func publishFocusedChat(_ candidate: UUID?) {
    let workspace = selectedWorkspace
    let agent = agentPage.flatMap { $0.id == candidate ? $0 : nil }
    store.setFocusedChat(
      candidate, serverId: agent?.serverId ?? workspace.serverId, sourceId: focusSourceId,
      workspaceId: workspace.id, isVisible: isVisible
    )
  }

  private func focusVisiblePage() {
    if isVisible { focusSelectedCenterPane() }
  }

  var contentColumn: some View {
    let workspace = selectedWorkspace
    let page = botPage
    return VStack(spacing: 0) {
      SessionScreen(
        centerGroup: activeCenterModel(in: workspace),
        focus: sessionFocus,
        onWorkspaceCommand: handleWorkspaceCommand,
        centerTree: visibleTree(liveCenterTree ?? workspace.centerTree),
        primaryLeafId: session.flatMap { workspace.centerTree.groupId(containingChat: $0.id) },
        activeLeafId: activeLeafId,
        centerLeafModel: { leafId in configuredCenterModel(leafId: leafId) },
        centerPaneTitle: paneTitle,
        sessionStore: store,
        splitDragCoordinator: splitDragCoordinator,
        onSplitLeaf: splitLeaf,
        onCloseLeaf: closeLeaf,
        onFloatLeaf: floatLeaf,
        openingSplit: openingSplit,
        onSplitOpeningFinished: finishSplitOpening,
        onCenterTreeChanged: { visible in
          let tree = restoringHiddenLeaves(visible)
          liveCenterTree = tree
          saveSelectedTree(tree, workspaceId: workspace.id)
        },
        onCenterTreeLiveChanged: { visible in liveCenterTree = restoringHiddenLeaves(visible) }
      )
      .overlay { floatingPaneOverlay }
      .environment(\.usesSlimComposer, WorkspaceLayoutPolicy.usesBotChrome(page))
      .environment(\.botPage, page ?? .conversation)
    }
    .overlay(alignment: .top) {
      if WorkspaceLayoutPolicy.showsTitlebarDivider(workspace, showing: page, environment: environment) {
        Color.separatorColor
          .frame(height: 1)
          .frame(maxWidth: .infinity)
      }
    }
  }
}
