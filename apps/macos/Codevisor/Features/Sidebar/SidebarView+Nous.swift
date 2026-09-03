import CodevisorCore
import CodevisorUI
import SwiftUI

/// Nous (prototype): a workspace's top tabs ARE its sidebar rows. Each
/// expanded workspace lists its `centerTabs` — chat, terminal, plugin, or
/// the New Tab placeholder — in place of the in-content tab strip, so ⌘T
/// inside a workspace adds a row here and the strip never renders.
///
/// The sidebar only *asks* for tab changes. Selecting a chat tab routes
/// through its chat like any chat row; anything else rides the workspace's
/// routing chat and hands the mounted container a `CenterTabRequest` that
/// names the tab (see `SessionContainerView`).
extension SidebarView {
  var isNousMode: Bool { organization == .nous }

  /// Every tab row's identity in sidebar order: the reflow animation value,
  /// and how additions reveal their workspace.
  var nousTabIDs: [UUID] {
    guard isNousMode else { return [] }
    return workspaceItems.flatMap { item in
      item.workspace.centerTabs.flatMap { tab in [tab.id] + tab.root.allGroups.map(\.id) }
    }
  }

  // MARK: - Rows

  @ViewBuilder
  func nousTabRows(_ item: SidebarWorkspaceListItem) -> some View {
    let workspace = item.workspace
    let routesSelection = routesSelectedSession(workspace)
    ForEach(workspace.centerTabs) { tab in
      // A split tab is FLATTENED into one row per pane at the tab's own
      // level (no grouping row): the active pane carries the selection.
      if tab.root.allGroups.count > 1 {
        ForEach(tab.root.allGroups, id: \.id) { leaf in
          nousPaneRow(
            leafId: leaf.id,
            state: leaf.state,
            tab: tab,
            in: item,
            routesSelection: routesSelection
          )
          .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
      } else {
        nousTabRow(tab, in: item, routesSelection: routesSelection)
          .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
      }
    }
  }

  private func nousPaneRow(
    leafId: UUID,
    state: PaneGroupState,
    tab: WorkspaceTab,
    in item: SidebarWorkspaceListItem,
    routesSelection: Bool
  ) -> some View {
    let workspace = item.workspace
    let descriptor = nousLeafDescriptor(leafId: leafId, persisted: state, in: workspace)
    let chatSession = descriptor.flatMap { nousChatSession($0, serverId: workspace.serverId) }
    return SidebarWorkspaceTabRow(
      title: nousPaneTitle(descriptor, chatSession: chatSession),
      kind: descriptor?.kind ?? .newTab,
      isAgentOwned: descriptor?.attachOnly ?? false,
      chatSession: chatSession,
      store: store,
      isSelected: routesSelection && workspace.selectedCenterTabId == tab.id
        && tab.activeLeafId == leafId,
      isReordering: isReordering,
      titleFont: itemTitleFont,
      hierarchyIndent: hierarchyIndent,
      onActivate: { activateNousLeaf(leafId, state: state, in: item) },
      onClose: { requestNousTabAction(.closeLeaf(leafId), in: item) },
      closeTitle: "Close Pane"
    )
  }

  private func nousTabRow(
    _ tab: WorkspaceTab,
    in item: SidebarWorkspaceListItem,
    routesSelection: Bool
  ) -> some View {
    let workspace = item.workspace
    let descriptor = nousTabDescriptor(tab, in: workspace)
    let chatSession = descriptor.flatMap { nousChatSession($0, serverId: workspace.serverId) }
    return SidebarWorkspaceTabRow(
      title: nousTabTitle(tab, descriptor: descriptor, chatSession: chatSession),
      kind: descriptor?.kind ?? .newTab,
      isAgentOwned: descriptor?.attachOnly ?? false,
      chatSession: chatSession,
      store: store,
      isSelected: routesSelection && workspace.selectedCenterTabId == tab.id,
      isReordering: isReordering,
      titleFont: itemTitleFont,
      hierarchyIndent: hierarchyIndent,
      onActivate: { activateNousTab(tab, in: item) },
      onClose: { closeNousTab(tab, in: item) },
      onRename: {
        nousTabRenameTitle = nousTabTitle(tab, descriptor: descriptor, chatSession: chatSession)
        renamingNousTab = NousTabRenameRequest(workspaceId: workspace.id, tabId: tab.id)
      }
    )
  }

  /// The pane that names the tab: its active leaf's selected pane. A
  /// mounted leaf's live model runs ahead of the repository mid-edit (a New
  /// Tab converting into a terminal), so prefer it when there is one.
  private func nousTabDescriptor(_ tab: WorkspaceTab, in workspace: Workspace) -> PaneDescriptorState? {
    nousLeafDescriptor(
      leafId: tab.activeLeafId, persisted: tab.root.group(id: tab.activeLeafId), in: workspace
    ) ?? tab.root.allGroups.first?.state.selectedPane
  }

  private func nousLeafDescriptor(
    leafId: UUID,
    persisted: PaneGroupState?,
    in workspace: Workspace
  ) -> PaneDescriptorState? {
    let liveKey = SessionStore.CenterLeafKey(workspaceId: workspace.id, groupId: leafId)
    return store?.centerLeafGroups[liveKey]?.state.selectedPane ?? persisted?.selectedPane
  }

  private func nousPaneTitle(_ descriptor: PaneDescriptorState?, chatSession: ChatSession?) -> String {
    guard let descriptor else { return "New Tab" }
    if descriptor.kind == .chat { return chatSession?.title ?? descriptor.name }
    return descriptor.name
  }

  private func nousTabTitle(
    _ tab: WorkspaceTab,
    descriptor: PaneDescriptorState?,
    chatSession: ChatSession?
  ) -> String {
    if let customTitle = tab.customTitle { return customTitle }
    // Chat tabs follow the session's LIVE title (auto-titles, renames).
    return nousPaneTitle(descriptor, chatSession: chatSession)
  }

  private func nousChatSession(_ descriptor: PaneDescriptorState, serverId: String) -> ChatSession? {
    guard descriptor.kind == .chat, let id = descriptor.chatSessionId else { return nil }
    return list.sessions.first { $0.serverId == serverId && $0.id == id }
  }

  /// The live chat a tab can route through: its selected pane's chat first,
  /// else any chat pane inside the tab's splits.
  private func nousRoutableChat(in tab: WorkspaceTab, serverId: String) -> ChatSession? {
    let selected = tab.root.group(id: tab.activeLeafId)?.selectedPane.map { [$0] } ?? []
    let panes = selected + tab.root.allGroups.flatMap(\.state.panes)
    for pane in panes where pane.kind == .chat {
      guard let id = pane.chatSessionId,
        let session = list.sessions.first(where: {
          $0.serverId == serverId && $0.id == id && !$0.isArchived
        })
      else { continue }
      return session
    }
    return nil
  }

  // MARK: - Actions

  func activateNousTab(_ tab: WorkspaceTab, in item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    store?.centerTabRequest = CenterTabRequest(workspaceId: workspace.id, action: .select(tab.id))
    if let chat = nousRoutableChat(in: tab, serverId: workspace.serverId) {
      activateSession(chat)
    } else if !routesSelectedSession(workspace), let routing = item.primarySession {
      activateSession(routing)
    }
  }

  /// A pane row: name the leaf, and route through its own chat when it
  /// has one so the sidebar selection lands right immediately.
  func activateNousLeaf(_ leafId: UUID, state: PaneGroupState, in item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    store?.centerTabRequest = CenterTabRequest(workspaceId: workspace.id, action: .selectLeaf(leafId))
    if let pane = state.selectedPane, let chat = nousChatSession(pane, serverId: workspace.serverId),
      !chat.isArchived
    {
      activateSession(chat)
    } else if !routesSelectedSession(workspace), let routing = item.primarySession {
      activateSession(routing)
    }
  }

  func closeNousTab(_ tab: WorkspaceTab, in item: SidebarWorkspaceListItem) {
    requestNousTabAction(.close(tab.id), in: item)
  }

  func addNousTab(in item: SidebarWorkspaceListItem) {
    requestNousTabAction(.new, in: item)
  }

  /// Closing and adding run the container's machinery, so a workspace that
  /// is not on screen is routed to first (its container consumes the
  /// request as it mounts).
  private func requestNousTabAction(_ action: CenterTabRequest.Action, in item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    store?.centerTabRequest = CenterTabRequest(workspaceId: workspace.id, action: action)
    if !routesSelectedSession(workspace), let routing = item.primarySession {
      activateSession(routing)
    }
  }

  /// A rename is a plain layout write (no pane machinery), so the sidebar
  /// applies it directly.
  func renameNousTab(_ request: NousTabRenameRequest, to title: String) {
    guard var workspace = environment.workspaces.workspace(id: request.workspaceId),
      let index = workspace.centerTabs.firstIndex(where: { $0.id == request.tabId })
    else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.isEmpty ? nil : trimmed
    guard workspace.centerTabs[index].customTitle != normalized else { return }
    workspace.centerTabs[index].customTitle = normalized
    environment.workspaces.save(workspace)
    workspaceRevision += 1
  }

  // MARK: - Keyboard stepping

  /// One sidebar row: a single-pane tab, or one pane of a split tab.
  private struct NousEntry {
    let item: SidebarWorkspaceListItem
    let tab: WorkspaceTab
    /// Nil for a single-pane tab (the tab itself is the row).
    let leaf: (id: UUID, state: PaneGroupState)?
  }

  /// The flat list exactly as the sidebar renders it, across workspaces.
  private var nousEntries: [NousEntry] {
    workspaceItems.flatMap { item in
      item.workspace.centerTabs.flatMap { tab -> [NousEntry] in
        let groups = tab.root.allGroups
        guard groups.count > 1 else { return [NousEntry(item: item, tab: tab, leaf: nil)] }
        return groups.map { NousEntry(item: item, tab: tab, leaf: ($0.id, $0.state)) }
      }
    }
  }

  /// ⇧⌘[ / ⇧⌘]: moves to the previous/next row of the flat list, crossing
  /// workspace boundaries but stopping at either end (no wrap). False when
  /// the routed workspace is not listed (filtered out), letting the
  /// container cycle locally.
  func stepNous(_ offset: Int) -> Bool {
    guard isNousMode else { return false }
    let entries = nousEntries
    guard !entries.isEmpty,
      let current = entries.firstIndex(where: { entry in
        routesSelectedSession(entry.item.workspace)
          && entry.item.workspace.selectedCenterTabId == entry.tab.id
          && (entry.leaf == nil || entry.leaf?.id == entry.tab.activeLeafId)
      })
    else { return false }
    let targetIndex = current + offset
    // At the end of the list the key is consumed but nothing moves — the
    // container must not fall back to wrapping within its own tabs.
    guard entries.indices.contains(targetIndex) else { return true }
    let target = entries[targetIndex]
    withAnimation(.snappy(duration: 0.28)) {
      expandedWorkspaces.insert(target.item.workspace.id)
    }
    if let leaf = target.leaf {
      activateNousLeaf(leaf.id, state: leaf.state, in: target.item)
    } else {
      activateNousTab(target.tab, in: target.item)
    }
    return true
  }

  // MARK: - Disclosure

  /// Entering Nous opens the workspace the current chat lives in: the
  /// mode exists to put that workspace's tabs in view.
  func revealRoutedNousWorkspace() {
    guard isNousMode, case let .session(_, sessionId) = selection,
      let workspaceId = environment.workspaces.workspaceId(forSession: sessionId)
    else { return }
    withAnimation(.snappy(duration: 0.28)) {
      expandedWorkspaces.insert(workspaceId)
    }
  }

  /// Expand only for additions — not ordinary selection changes — so
  /// navigating among tabs never overrides the user's disclosure choices.
  func revealNousTabWorkspaces(added addedTabIDs: Set<UUID>) {
    guard isNousMode, !addedTabIDs.isEmpty else { return }
    let workspaceIDs =
      workspaceItems
      .filter { item in item.workspace.centerTabs.contains { addedTabIDs.contains($0.id) } }
      .map(\.workspace.id)
    guard !workspaceIDs.isEmpty else { return }
    withAnimation(.snappy(duration: 0.28)) {
      expandedWorkspaces.formUnion(workspaceIDs)
    }
  }
}

/// The tab a rename alert is editing.
struct NousTabRenameRequest: Identifiable, Equatable {
  let workspaceId: UUID
  let tabId: UUID
  var id: UUID { tabId }
}

/// The Nous tab rename alert, chained after the sidebar's other alerts.
struct NousTabRenameAlert: ViewModifier {
  @Binding var request: NousTabRenameRequest?
  @Binding var title: String
  let onRename: (NousTabRenameRequest, String) -> Void

  func body(content: Content) -> some View {
    content
      .alert(
        "Rename Tab",
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
