import CodevisorCore
import CodevisorUI
import SwiftUI

extension ClassicSidebarView {
  func tabRowIDs(in workspace: Workspace) -> [UUID] {
    workspace.centerTabs.flatMap { tab -> [UUID] in
      let groups = tab.root.allGroups
      return groups.count > 1 ? groups.map(\.id) : [tab.id]
    }
  }

  @ViewBuilder
  func workspaceTabRows(_ item: SidebarWorkspaceListItem) -> some View {
    let workspace = item.workspace
    let routesSelection = routesSelectedSession(workspace)
    ForEach(workspace.centerTabs) { tab in
      VStack(alignment: .leading, spacing: 1) {
        tabRows(tab, in: item, routesSelection: routesSelection)
      }
      .opacity(draggingID == tab.id ? 0.4 : 1)
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: .named(Self.reorderSpace))
      } action: { frame in
        recordTabFrame(frame, for: tab.id)
      }
      .onDisappear { forgetTabGeometry(for: tab.id) }
      .simultaneousGesture(reorderGesture(for: .tab(tab.id, workspaceID: workspace.id)))
      .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }
  }

  @ViewBuilder
  func tabRows(_ tab: WorkspaceTab, in item: SidebarWorkspaceListItem, routesSelection: Bool) -> some View {
    let groups = tab.root.allGroups
    if groups.count > 1 {
      ForEach(groups, id: \.id) { leaf in
        workspacePaneRow(
          leafId: leaf.id,
          state: leaf.state,
          tab: tab,
          in: item,
          routesSelection: routesSelection
        )
      }
    } else {
      workspaceTabRow(tab, in: item, routesSelection: routesSelection)
    }
  }

  private func workspacePaneRow(
    leafId: UUID,
    state: PaneGroupState,
    tab: WorkspaceTab,
    in item: SidebarWorkspaceListItem,
    routesSelection: Bool
  ) -> some View {
    let workspace = item.workspace
    let descriptor = leafDescriptor(leafId: leafId, persisted: state, in: workspace)
    let chatSession = descriptor.flatMap { sessionForPane($0, serverId: workspace.serverId) }
    return SidebarWorkspaceTabRow(
      title: paneTitle(descriptor, chatSession: chatSession),
      kind: descriptor?.kind ?? .newTab,
      browserFavicon: browserFavicon(descriptor),
      pluginId: descriptor?.pluginId,
      pluginPaneType: descriptor?.pluginPaneType,
      pluginIconClient: environment.machines.client(for: workspace.serverId),
      pluginIconCacheNamespace: workspace.serverId,
      chatSession: chatSession,
      terminalStatus: descriptor?.terminalAgentStatus,
      subagentHarnessId: descriptor.flatMap { subagentHarnessId($0, serverId: workspace.serverId) },
      store: store,
      isSelected: routesSelection && workspace.selectedCenterTabId == tab.id
        && tab.activeLeafId == leafId,
      isReordering: isReordering,
      titleFont: itemTitleFont,
      onActivate: { activateLeaf(leafId, state: state, in: item) },
      onClose: { requestTabAction(.closeLeaf(leafId), in: item) },
      onRename: chatSession.map { session in
        {
          tabRenameTitle = session.title
          renamingTab = SidebarTabRenameRequest(
            workspaceId: workspace.id, tabId: tab.id, chatSessionId: session.id
          )
        }
      }
    )
  }

  private func workspaceTabRow(
    _ tab: WorkspaceTab,
    in item: SidebarWorkspaceListItem,
    routesSelection: Bool
  ) -> some View {
    let workspace = item.workspace
    let descriptor = tabDescriptor(tab, in: workspace)
    let chatSession = descriptor.flatMap { sessionForPane($0, serverId: workspace.serverId) }
    return SidebarWorkspaceTabRow(
      title: tabTitle(tab, descriptor: descriptor, chatSession: chatSession),
      kind: descriptor?.kind ?? .newTab,
      browserFavicon: browserFavicon(descriptor),
      pluginId: descriptor?.pluginId,
      pluginPaneType: descriptor?.pluginPaneType,
      pluginIconClient: environment.machines.client(for: workspace.serverId),
      pluginIconCacheNamespace: workspace.serverId,
      chatSession: chatSession,
      terminalStatus: descriptor?.terminalAgentStatus,
      subagentHarnessId: descriptor.flatMap { subagentHarnessId($0, serverId: workspace.serverId) },
      store: store,
      isSelected: routesSelection && workspace.selectedCenterTabId == tab.id,
      isReordering: isReordering,
      titleFont: itemTitleFont,
      onActivate: { activateTab(tab, in: item) },
      onClose: { closeTab(tab, in: item) },
      onRename: {
        tabRenameTitle = tabTitle(tab, descriptor: descriptor, chatSession: chatSession)
        renamingTab = SidebarTabRenameRequest(workspaceId: workspace.id, tabId: tab.id, chatSessionId: chatSession?.id)
      }
    )
  }

  private func tabDescriptor(_ tab: WorkspaceTab, in workspace: Workspace) -> PaneDescriptorState? {
    leafDescriptor(
      leafId: tab.activeLeafId, persisted: tab.root.group(id: tab.activeLeafId), in: workspace
    ) ?? tab.root.allGroups.first?.state.selectedPane
  }

  private func leafDescriptor(
    leafId: UUID,
    persisted: PaneGroupState?,
    in workspace: Workspace
  ) -> PaneDescriptorState? {
    let liveKey = SessionStore.CenterLeafKey(workspaceId: workspace.id, groupId: leafId)
    guard var live = store?.centerLeafGroups[liveKey]?.state.selectedPane else { return persisted?.selectedPane }
    if let record = persisted?.panes.first(where: { $0.id == live.id }) {
      live.liveTitle = record.liveTitle
      live.terminalActivity = record.terminalActivity
    }
    return live
  }

  private func browserFavicon(_ descriptor: PaneDescriptorState?) -> NSImage? {
    guard let descriptor, descriptor.kind == .browser else { return nil }
    return store?.localBrowserModel(paneId: descriptor.id)?.favicon
  }

  private func paneTitle(_ descriptor: PaneDescriptorState?, chatSession: ChatSession?) -> String {
    guard let descriptor else { return "New Tab" }
    if descriptor.kind == .chat { return chatSession?.title ?? descriptor.name }
    if descriptor.kind == .browser, let title = store?.localBrowserTitle(paneId: descriptor.id) {
      return title
    }
    return descriptor.displayName
  }

  private func tabTitle(
    _ tab: WorkspaceTab,
    descriptor: PaneDescriptorState?,
    chatSession: ChatSession?
  ) -> String {
    if descriptor?.kind == .chat { return tab.displayTitle(for: descriptor, chatTitle: chatSession?.title) }
    if let customTitle = tab.customTitle { return customTitle }
    return paneTitle(descriptor, chatSession: chatSession)
  }

  private func subagentHarnessId(_ descriptor: PaneDescriptorState, serverId: String) -> String? {
    guard descriptor.kind == .subagent, let ownerId = descriptor.ownerChatSessionId else { return nil }
    return list.session(ownerId, serverId: serverId)?.harnessId
  }

  private func sessionForPane(_ descriptor: PaneDescriptorState, serverId: String) -> ChatSession? {
    guard descriptor.kind == .chat, let id = descriptor.chatSessionId else { return nil }
    return list.session(id, serverId: serverId)
  }

  private func routableChat(in tab: WorkspaceTab, serverId: String) -> ChatSession? {
    let selected = tab.root.group(id: tab.activeLeafId)?.selectedPane.map { [$0] } ?? []
    let panes = selected + tab.root.allGroups.flatMap(\.state.panes)
    for pane in panes where pane.kind == .chat {
      guard let id = pane.chatSessionId, let session = list.session(id, serverId: serverId) else { continue }
      return session
    }
    return nil
  }

  func activateTab(_ tab: WorkspaceTab, in item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    guard store?.selectDestination(.tab(tab.id), in: workspace.id) == true else { return }
    apply(
      workspace.selectionRoute(
        activatedChatSessionId: routableChat(in: tab, serverId: workspace.serverId)?.id,
        routingSessionId: item.routingSession?.id,
        selectionAlreadyRoutesWorkspace: routesSelectedSession(workspace)
      ))
  }

  func activateLeaf(_ leafId: UUID, state: PaneGroupState, in item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    guard store?.selectDestination(.leaf(leafId), in: workspace.id) == true else { return }
    let paneChat = state.selectedPane
      .flatMap { sessionForPane($0, serverId: workspace.serverId) }
    apply(
      workspace.selectionRoute(
        activatedChatSessionId: paneChat?.id,
        routingSessionId: item.routingSession?.id,
        selectionAlreadyRoutesWorkspace: routesSelectedSession(workspace)
      ))
  }

  private func apply(_ route: WorkspaceSelectionRoute?) {
    switch route {
    case let .session(serverId, id):
      selection = .session(serverId: serverId, id: id)
    case let .workspace(serverId, id):
      selection = .workspace(serverId: serverId, id: id)
    case nil:
      break
    }
  }

  func closeTab(_ tab: WorkspaceTab, in item: SidebarWorkspaceListItem) {
    requestTabAction(.close(tab.id), in: item)
  }

  func addTab(in item: SidebarWorkspaceListItem) {
    requestTabAction(.new, in: item)
  }

  private func requestTabAction(_ action: CenterTabRequest.Action, in item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    if !routesSelectedSession(workspace) {
      switch action {
      case .close, .closeLeaf:
        store?.closeBackgroundTab(action, in: workspace, routingSession: item.routingSession)
        return
      default:
        break
      }
    }
    store?.centerTabRequest = CenterTabRequest(workspaceId: workspace.id, action: action)
    if !routesSelectedSession(workspace), let routing = item.routingSession {
      activateSession(routing)
    }
  }

  func renameTab(_ request: SidebarTabRenameRequest, to title: String) {
    environment.workspaceSync.renameTab(
      workspaceId: request.workspaceId, tabId: request.tabId,
      chatSessionId: request.chatSessionId, to: title
    )
  }

  private enum SidebarTabEntry {
    case newChat
    case tab(item: SidebarWorkspaceListItem, tab: WorkspaceTab, leaf: (id: UUID, state: PaneGroupState)?)
  }

  private var tabEntries: [SidebarTabEntry] {
    [.newChat]
      + listedWorkspaceItems.flatMap { item in
        item.workspace.centerTabs.flatMap { tab -> [SidebarTabEntry] in
          let groups = tab.root.allGroups
          guard groups.count > 1 else { return [.tab(item: item, tab: tab, leaf: nil)] }
          return groups.map { .tab(item: item, tab: tab, leaf: ($0.id, $0.state)) }
        }
      }
  }

  func stepSidebarTab(_ offset: Int) -> Bool {
    let entries = tabEntries
    guard
      let current = entries.firstIndex(where: { entry in
        switch entry {
        case .newChat:
          return isNewChatSelected
        case let .tab(item, tab, leaf):
          return routesSelectedSession(item.workspace)
            && item.workspace.selectedCenterTabId == tab.id
            && (leaf == nil || leaf?.id == tab.activeLeafId)
        }
      })
    else { return false }
    let targetIndex = current + offset
    guard entries.indices.contains(targetIndex) else { return true }
    switch entries[targetIndex] {
    case .newChat:
      selection = .newChat(nil)
    case let .tab(item, tab, leaf):
      if let leaf {
        activateLeaf(leaf.id, state: leaf.state, in: item)
      } else {
        activateTab(tab, in: item)
      }
    }
    return true
  }

}

struct SidebarTabRenameRequest: Identifiable, Equatable {
  let workspaceId: UUID
  let tabId: UUID
  var chatSessionId: UUID? = nil
  var id: UUID { tabId }
}

struct SidebarTabRenameAlert: ViewModifier {
  @Binding var request: SidebarTabRenameRequest?
  @Binding var title: String
  let onRename: (SidebarTabRenameRequest, String) -> Void

  func body(content: Content) -> some View {
    content
      .alert(
        request?.chatSessionId != nil ? "Rename Chat" : "Rename Tab",
        isPresented: Binding(
          get: { request != nil },
          set: { if !$0 { request = nil } }
        ),
        presenting: request
      ) { request in
        TextField("Title", text: $title)
        Button("Rename") {
          onRename(request, title)
        }
        Button("Cancel", role: .cancel) {}
      }
  }
}
