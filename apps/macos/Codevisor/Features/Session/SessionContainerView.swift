import SwiftUI
import CodevisorCore
import CodevisorUI
import SimulatorPane

struct SessionContainerView: View {
  enum Mount {
    case chat(ChatSession, SessionController, Workspace)
    case workspace(Workspace)
  }

  let mount: Mount
  let project: Project
  let store: SessionStore

  var session: ChatSession? {
    if case let .chat(session, _, _) = mount { return session }
    return nil
  }
  var controller: SessionController? {
    if case let .chat(_, controller, _) = mount { return controller }
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
    case let .chat(session, _, _): return session.id
    case let .workspace(snapshot): return snapshot.id
    }
  }

  var mountedWorkspace: Workspace {
    switch mount {
    case let .chat(_, _, workspace), let .workspace(workspace): workspace
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
  }

  private func mounted(in workspace: Workspace) -> some View {
    titledContentColumn
      .navigationSubtitle(activePaneSubtitle)
      .toolbar(removing: paneControlsReplaceTitle ? .title : nil)
      .toolbar {
        if let browser = activeBrowserModel {
          ChromiumBrowserNavigationControls(model: browser)
          ChromiumBrowserAddressToolbarItem(model: browser)
        } else if let pane = activeScreenSharingPane, let store = pane.store {
          ScreenSharingToolbar(
            store: store, settings: { pane.machineSettings() }, applySettings: { pane.applyMachineSettings($0) })
        } else if let model = activeFileModel {
          FilePaneToolbar(model: model, onNewTab: addCenterTab)
        } else if let model = activeReviewModel {
          ReviewPaneToolbar(model: model, title: activePaneTitle.wrappedValue)
        } else if let model = activeSimulatorModel {
          SimulatorPaneToolbar(model: model) { data, name in
            AppleSimulatorPane.saveScreenshot(data, deviceName: name)
          }
        }
      }
      .focusedSceneValue(\.browserPage, activeBrowserModel)
      .focusedSceneValue(\.filePane, activeFileModel)
      .focusedSceneValue(\.simulatorPane, activeSimulatorModel)
      .focusedSceneValue(\.workspaceLayoutActions, layoutActions(in: workspace))
      .environment(\.openFileDocument, OpenFileDocumentAction { openFileDocument($0) })
      .environment(
        \.openSubagent,
        OpenSubagentAction { parentId, toolCallId, title, placement in
          openSubagent(parentSessionId: parentId, toolCallId: toolCallId, title: title, placement: placement)
        }
      )
      .onChange(of: workspaceEntry.generation, initial: true) { _, _ in
        synchronizeMountedPaneGroups()
      }
      .onChange(of: store.newCenterTabRequest, initial: true) { _, request in
        guard let request, store.newCenterTabRequest == request,
          request.workspaceId == workspace.id
        else { return }
        store.newCenterTabRequest = nil
        addCenterTab()
      }
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
      .onChange(of: focusedChatCandidate, initial: true) { _, candidate in
        let workspace = selectedWorkspace
        store.setFocusedChat(
          candidate, serverId: workspace.serverId, sourceId: focusSourceId,
          workspaceId: workspace.id, isVisible: isVisible
        )
      }
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
  }

  var contentColumn: some View {
    let workspace = selectedWorkspace
    let showsTabBar = showsCenterTabBar(in: workspace)
    let chatLeaf = singlePaneChatLeaf(in: workspace)
    return VStack(spacing: 0) {
      if showsTabBar {
        WorkspaceTabBar(
          items: centerTabItems(in: workspace),
          selectedTabId: workspace.selectedCenterTabId,
          onSelect: selectCenterTab,
          onClose: closeCenterTab,
          onMove: moveCenterTab,
          onRename: renameCenterTab,
          onKeep: keepCenterTab,
          onNew: addCenterTab
        )
      }
      SessionScreen(
        controller: controller,
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
    }
    .overlay(alignment: .top) {
      if !showsTabBar && !isSinglePane {
        Color.separatorColor
          .frame(height: 1)
          .frame(maxWidth: .infinity)
      }
    }
  }
}
