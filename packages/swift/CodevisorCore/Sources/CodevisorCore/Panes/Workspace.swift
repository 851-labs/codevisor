import Foundation

public struct Workspace: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public var sidebarPosition: String?
  public var sidebarOrderRevision: Int = 0
  public var name: String
  public var hasCustomName: Bool
  public var rootDirectory: String?
  public var worktreeName: String?
  public let serverId: String
  public let projectId: UUID
  public var centerTabs: [WorkspaceTab]
  public var selectedCenterTabId: UUID
  public var createdAt: Date
  public var isArchived: Bool
  public var archivedAt: Date?
  public var isServerSynced: Bool
  public var git: ServerWorkspaceGit?
  public var botId: UUID?
  public var botMachineId: String?

  public var isDraft: Bool { !isServerSynced }

  private enum CodingKeys: String, CodingKey {
    case id, name, hasCustomName, rootDirectory, worktreeName, serverId
    case projectId, centerTabs, selectedCenterTabId, createdAt, isArchived, archivedAt
    case isServerSynced, sidebarPosition, sidebarOrderRevision, botId, botMachineId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sidebarPosition = try container.decodeIfPresent(String.self, forKey: .sidebarPosition)
    sidebarOrderRevision = try container.decodeIfPresent(Int.self, forKey: .sidebarOrderRevision) ?? 0
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    hasCustomName = try container.decode(Bool.self, forKey: .hasCustomName)
    rootDirectory = try container.decodeIfPresent(String.self, forKey: .rootDirectory)
    worktreeName = try container.decodeIfPresent(String.self, forKey: .worktreeName)
    serverId = try container.decode(String.self, forKey: .serverId)
    projectId = try container.decode(UUID.self, forKey: .projectId)
    let decodedTabs = try container.decode([WorkspaceTab].self, forKey: .centerTabs)
    if decodedTabs.isEmpty {
      let replacement = WorkspaceTab.placeholder()
      centerTabs = [replacement]
      selectedCenterTabId = replacement.id
    } else {
      centerTabs = decodedTabs
      let decodedSelection = try container.decodeIfPresent(UUID.self, forKey: .selectedCenterTabId)
      selectedCenterTabId =
        decodedSelection.flatMap { candidate in decodedTabs.contains { $0.id == candidate } ? candidate : nil }
        ?? decodedTabs[0].id
    }
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
    isServerSynced = try container.decodeIfPresent(Bool.self, forKey: .isServerSynced) ?? false
    botId = try container.decodeIfPresent(UUID.self, forKey: .botId)
    botMachineId = try container.decodeIfPresent(String.self, forKey: .botMachineId)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(hasCustomName, forKey: .hasCustomName)
    try container.encodeIfPresent(rootDirectory, forKey: .rootDirectory)
    try container.encodeIfPresent(worktreeName, forKey: .worktreeName)
    try container.encode(serverId, forKey: .serverId)
    try container.encode(projectId, forKey: .projectId)
    try container.encode(centerTabs, forKey: .centerTabs)
    try container.encode(selectedCenterTabId, forKey: .selectedCenterTabId)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(isArchived, forKey: .isArchived)
    try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
    try container.encode(isServerSynced, forKey: .isServerSynced)
    try container.encodeIfPresent(sidebarPosition, forKey: .sidebarPosition)
    try container.encode(sidebarOrderRevision, forKey: .sidebarOrderRevision)
    try container.encodeIfPresent(botId, forKey: .botId)
    try container.encodeIfPresent(botMachineId, forKey: .botMachineId)
  }

  public init(
    id: UUID = UUID(),
    name: String,
    hasCustomName: Bool = false,
    rootDirectory: String?,
    worktreeName: String? = nil,
    serverId: String,
    projectId: UUID,
    centerTree: SplitNode,
    createdAt: Date = Date(),
    isArchived: Bool = false,
    isServerSynced: Bool = false,
    sidebarOrderHead: String? = WorkspaceOrderClock.shared.head
  ) {
    self.id = id
    self.name = name
    self.hasCustomName = hasCustomName
    self.rootDirectory = rootDirectory
    self.worktreeName = worktreeName
    self.serverId = serverId
    self.projectId = projectId
    let tab = WorkspaceTab(root: centerTree)
    self.centerTabs = [tab]
    self.selectedCenterTabId = tab.id
    self.createdAt = createdAt
    self.isArchived = isArchived
    self.isServerSynced = isServerSynced
    self.sidebarPosition = WorkspacePosition.initial(
      createdAt: createdAt, id: id, after: isServerSynced ? nil : sidebarOrderHead
    )
  }

  public init(
    id: UUID = UUID(),
    name: String,
    hasCustomName: Bool = false,
    rootDirectory: String?,
    worktreeName: String? = nil,
    serverId: String,
    projectId: UUID,
    centerTabs: [WorkspaceTab],
    selectedCenterTabId: UUID? = nil,
    createdAt: Date = Date(),
    isArchived: Bool = false,
    isServerSynced: Bool = false,
    sidebarOrderHead: String? = WorkspaceOrderClock.shared.head
  ) {
    precondition(!centerTabs.isEmpty, "A workspace must contain at least one center tab")
    self.id = id
    self.name = name
    self.hasCustomName = hasCustomName
    self.rootDirectory = rootDirectory
    self.worktreeName = worktreeName
    self.serverId = serverId
    self.projectId = projectId
    self.centerTabs = centerTabs
    self.selectedCenterTabId =
      selectedCenterTabId.flatMap { candidate in
        centerTabs.contains { $0.id == candidate } ? candidate : nil
      } ?? centerTabs[0].id
    self.createdAt = createdAt
    self.isArchived = isArchived
    self.isServerSynced = isServerSynced
    self.sidebarPosition = WorkspacePosition.initial(
      createdAt: createdAt, id: id, after: isServerSynced ? nil : sidebarOrderHead
    )
  }

  public var centerTree: SplitNode {
    get { selectedCenterTab?.root ?? centerTabs[0].root }
    set {
      guard let index = selectedCenterTabIndex else { return }
      centerTabs[index].root = newValue
      if newValue.group(id: centerTabs[index].activeLeafId) == nil,
        let first = newValue.allGroups.first?.id
      {
        centerTabs[index].activeLeafId = first
      }
    }
  }

  public var selectedCenterTabIndex: Int? {
    centerTabs.firstIndex { $0.id == selectedCenterTabId }
  }

  public var selectedCenterTab: WorkspaceTab? {
    selectedCenterTabIndex.map { centerTabs[$0] }
  }

  public func tabId(containingChat sessionId: UUID) -> UUID? {
    centerTabs.first { $0.root.groupId(containingChat: sessionId) != nil }?.id
  }

  public func selectedPane(inLeaf leafId: UUID) -> PaneDescriptorState? {
    centerTabs.lazy.compactMap { $0.root.group(id: leafId)?.selectedPane }.first
  }

  public var focusedPane: PaneDescriptorState? {
    selectedCenterTab.flatMap { $0.root.group(id: $0.activeLeafId)?.selectedPane }
  }

  public var focusedChatSessionId: UUID? {
    if let pane = focusedPane, pane.kind == .chat, let sessionId = pane.chatSessionId {
      return sessionId
    }
    return allPanes.first { $0.kind == .chat && $0.chatSessionId != nil }?.chatSessionId
  }

  public func pane(containingChat sessionId: UUID) -> PaneDescriptorState? {
    centerTabs.lazy
      .flatMap { $0.root.allGroups }
      .flatMap(\.state.panes)
      .first { $0.kind == .chat && $0.chatSessionId == sessionId }
  }

  @discardableResult
  public mutating func upsertCenterPane(
    _ pane: PaneDescriptorState,
    selecting: Bool = true
  ) -> UUID {
    for tabIndex in centerTabs.indices {
      for group in centerTabs[tabIndex].root.allGroups {
        guard group.state.panes.contains(where: { $0.id == pane.id }) else { continue }
        centerTabs[tabIndex].root = centerTabs[tabIndex].root.updatingGroup(
          id: group.id
        ) { state in
          var state = state
          guard let paneIndex = state.panes.firstIndex(where: { $0.id == pane.id }) else {
            return state
          }
          state.panes[paneIndex] = pane
          if selecting { state.selectedPaneId = pane.id }
          return state
        }
        if selecting {
          centerTabs[tabIndex].activeLeafId = group.id
          selectedCenterTabId = centerTabs[tabIndex].id
        }
        return centerTabs[tabIndex].id
      }
    }

    let state = PaneGroupState(
      panes: [pane], selectedPaneId: pane.id
    )
    let tab = WorkspaceTab(root: .leaf(state))
    centerTabs.append(tab)
    if selecting { selectedCenterTabId = tab.id }
    return tab.id
  }

  public var hasOpenNonChatContent: Bool {
    centerTabs.contains { tab in
      tab.root.allGroups.contains { group in
        group.state.panes.contains { $0.kind != .chat && !$0.kind.isDeviceLocal }
      }
    }
  }

  public var chatSessionIds: [UUID] {
    centerTabs.flatMap { tab in
      tab.root.allGroups.flatMap { group in
        group.state.panes.compactMap { $0.kind == .chat ? $0.chatSessionId : nil }
      }
    }
  }

  public var allPanes: [PaneDescriptorState] {
    centerTabs.flatMap { $0.root.allGroups.flatMap(\.state.panes) }
  }

  public var hasRealPanes: Bool {
    allPanes.contains { !$0.kind.isDeviceLocal }
  }

  public mutating func pruneClosedCenterTab(_ tabId: UUID) {
    guard let index = centerTabs.firstIndex(where: { $0.id == tabId }) else { return }
    let oldLeaves = centerTabs[index].root.allGroups.map(\.id)
    let oldActiveLeaf = centerTabs[index].activeLeafId
    if let root = centerTabs[index].root.prunedEmptyGroups {
      centerTabs[index].root = root
      if root.group(id: oldActiveLeaf) == nil {
        let survivors = root.allGroups.map(\.id)
        let oldIndex = oldLeaves.firstIndex(of: oldActiveLeaf) ?? 0
        centerTabs[index].activeLeafId = survivors[min(oldIndex, survivors.count - 1)]
      }
    } else {
      centerTabs.remove(at: index)
    }
    if centerTabs.isEmpty {
      let replacement = WorkspaceTab.placeholder()
      centerTabs = [replacement]
      selectedCenterTabId = replacement.id
    } else if !centerTabs.contains(where: { $0.id == selectedCenterTabId }) {
      selectedCenterTabId = Self.replacementTab(afterRemovingAt: index, from: centerTabs).id
    }
  }

  mutating func selectReplacementForClosedTab(_ closedTabId: UUID, previousTabs: [WorkspaceTab]) {
    guard !centerTabs.isEmpty, !centerTabs.contains(where: { $0.id == closedTabId }),
      let oldIndex = previousTabs.firstIndex(where: { $0.id == closedTabId })
    else { return }
    let tabs = centerTabs
    let index =
      previousTabs[(oldIndex + 1)...].lazy
      .compactMap { next in tabs.firstIndex(where: { $0.id == next.id }) }
      .first ?? tabs.count
    selectedCenterTabId = Self.replacementTab(afterRemovingAt: index, from: tabs).id
  }

  static func replacementTab(
    afterRemovingAt index: Int, from tabs: [WorkspaceTab]
  ) -> WorkspaceTab {
    index > 0 ? tabs[index - 1] : tabs[0]
  }

  public func selectionRoute(
    activatedChatSessionId: UUID?,
    routingSessionId: UUID?,
    selectionAlreadyRoutesWorkspace: Bool
  ) -> WorkspaceSelectionRoute? {
    if let activatedChatSessionId {
      return .session(serverId: serverId, id: activatedChatSessionId)
    }
    if selectionAlreadyRoutesWorkspace { return nil }
    if let routingSessionId {
      return .session(serverId: serverId, id: routingSessionId)
    }
    return .workspace(serverId: serverId, id: id)
  }

  @discardableResult
  public mutating func selectDestination(_ destination: WorkspaceDestination) -> Bool {
    let tabIndex: Int
    let leafId: UUID
    switch destination {
    case let .tab(id):
      guard let index = centerTabs.firstIndex(where: { $0.id == id }),
        let active = centerTabs[index].resolvedActiveLeafId(preferred: nil)
      else { return false }
      tabIndex = index
      leafId = active
    case let .leaf(id):
      guard let index = centerTabs.firstIndex(where: { $0.root.group(id: id) != nil }) else {
        return false
      }
      tabIndex = index
      leafId = id
    case let .chat(id):
      guard let index = centerTabs.firstIndex(where: { $0.root.groupId(containingChat: id) != nil }),
        let leaf = centerTabs[index].root.groupId(containingChat: id)
      else { return false }
      tabIndex = index
      leafId = leaf
      centerTabs[index].root = centerTabs[index].root.updatingGroup(id: leaf) { state in
        var state = state
        if let pane = state.panes.first(where: { $0.kind == .chat && $0.chatSessionId == id }) {
          state.selectPane(id: pane.id)
        }
        return state
      }
    case let .pane(id):
      guard
        let index = centerTabs.firstIndex(where: { tab in
          tab.root.allGroups.contains { $0.state.panes.contains { $0.id == id } }
        }),
        let leaf = centerTabs[index].root.allGroups.first(where: {
          $0.state.panes.contains { $0.id == id }
        })
      else { return false }
      tabIndex = index
      leafId = leaf.id
      centerTabs[index].root = centerTabs[index].root.updatingGroup(id: leaf.id) { state in
        var state = state
        state.selectPane(id: id)
        return state
      }
    }
    centerTabs[tabIndex].activeLeafId = leafId
    selectedCenterTabId = centerTabs[tabIndex].id
    return true
  }

  public mutating func insertBrowserPane(
    _ pane: PaneDescriptorState, from sourcePaneId: UUID, destination: BrowserLinkDestination
  ) -> (tabId: UUID, leafId: UUID)? {
    guard pane.kind == .browser else { return nil }
    return insertPane(pane, besidePane: sourcePaneId, destination: destination)
  }

  public mutating func insertPane(
    _ pane: PaneDescriptorState, besidePane sourcePaneId: UUID, destination: BrowserLinkDestination
  ) -> (tabId: UUID, leafId: UUID)? {
    guard let index = centerTabs.firstIndex(where: { $0.root.groupId(containingPane: sourcePaneId) != nil }),
      let sourceLeaf = centerTabs[index].root.groupId(containingPane: sourcePaneId),
      !centerTabs.contains(where: { $0.root.groupId(containingPane: pane.id) != nil })
    else { return nil }
    let state = PaneGroupState(panes: [pane], selectedPaneId: pane.id)
    if case let .split(edge) = destination {
      let leafId = UUID()
      centerTabs[index].root = centerTabs[index].root.splitting(
        groupId: sourceLeaf, edge: edge, newGroupId: leafId, newGroupState: state)
      centerTabs[index].activeLeafId = leafId
      return (centerTabs[index].id, leafId)
    }
    let tab = WorkspaceTab(root: .leaf(state))
    centerTabs.insert(tab, at: index + 1)
    return (tab.id, tab.activeLeafId)
  }

  @discardableResult
  public mutating func pruneOrphanedSubagentPanes() -> [PaneDescriptorState] {
    let chats = Set(chatSessionIds)
    let orphans = allPanes.filter { pane in
      (pane.kind == .subagent || pane.kind == .transcript) && !(pane.ownerChatSessionId.map(chats.contains) ?? false)
    }
    guard !orphans.isEmpty else { return [] }
    for orphan in orphans {
      WorkspacePaneReconciler.removePane(id: orphan.id, from: &self)
    }
    WorkspacePaneReconciler.pruneEmptyCenterTabs(in: &self)
    WorkspacePaneReconciler.ensureUsableLayout(&self)
    return orphans
  }

  public mutating func replacePane(
    id: UUID, with pane: PaneDescriptorState
  ) -> (tabId: UUID, leafId: UUID)? {
    guard !centerTabs.contains(where: { $0.root.groupId(containingPane: pane.id) != nil }),
      let index = centerTabs.firstIndex(where: { $0.root.groupId(containingPane: id) != nil }),
      let leafId = centerTabs[index].root.groupId(containingPane: id)
    else { return nil }
    centerTabs[index].root = centerTabs[index].root.updatingGroup(id: leafId) { state in
      var state = state
      guard let position = state.panes.firstIndex(where: { $0.id == id }) else { return state }
      state.panes[position] = pane
      state.selectedPaneId = pane.id
      return state
    }
    centerTabs[index].activeLeafId = leafId
    return (centerTabs[index].id, leafId)
  }
}

public enum WorkspaceDestination: Hashable, Sendable {
  case tab(UUID)
  case leaf(UUID)
  case chat(UUID)
  case pane(UUID)
}

public enum WorkspaceSelectionRoute: Hashable, Sendable {
  case session(serverId: String, id: UUID)
  case workspace(serverId: String, id: UUID)
}

public enum BrowserLinkDestination: Equatable, Sendable {
  case backgroundTab
  case foregroundTab
  case window
  case split(SplitEdge)
}
