import Foundation

public struct WorkspaceTab: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public var customTitle: String?
  public var root: SplitNode
  public var activeLeafId: UUID
  public var isPreview: Bool

  public init(
    id: UUID = UUID(),
    customTitle: String? = nil,
    root: SplitNode,
    activeLeafId: UUID? = nil,
    isPreview: Bool = false
  ) {
    self.id = id
    self.customTitle = customTitle
    self.root = root
    self.isPreview = isPreview
    self.activeLeafId =
      activeLeafId.flatMap { root.group(id: $0) != nil ? $0 : nil }
      ?? root.allGroups.first?.id
      ?? UUID()
  }

  private enum CodingKeys: String, CodingKey { case id, customTitle, root, activeLeafId, isPreview }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
    isPreview = try container.decodeIfPresent(Bool.self, forKey: .isPreview) ?? false
    let decodedRoot = try container.decode(SplitNode.self, forKey: .root)
    root = decodedRoot
    let decoded = try container.decodeIfPresent(UUID.self, forKey: .activeLeafId)
    activeLeafId =
      decoded.flatMap { decodedRoot.group(id: $0) != nil ? $0 : nil }
      ?? decodedRoot.allGroups.first?.id
      ?? UUID()
  }

  public static func placeholder() -> WorkspaceTab {
    WorkspaceTab(root: .leaf(.centerInitialWithoutChat()))
  }

  public var isPlaceholder: Bool {
    root.allGroups.allSatisfy { group in group.state.panes.allSatisfy { $0.kind == .newTab } }
  }
}

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
  public var isServerSynced: Bool
  public var git: ServerWorkspaceGit?
  public var botId: UUID?

  public var isDraft: Bool { !isServerSynced }

  private enum CodingKeys: String, CodingKey {
    case id, name, hasCustomName, rootDirectory, worktreeName, serverId
    case projectId, centerTabs, selectedCenterTabId, createdAt, isArchived
    case isServerSynced, sidebarPosition, sidebarOrderRevision, botId
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
    isServerSynced = try container.decodeIfPresent(Bool.self, forKey: .isServerSynced) ?? false
    botId = try container.decodeIfPresent(UUID.self, forKey: .botId)
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
    try container.encode(isServerSynced, forKey: .isServerSynced)
    try container.encodeIfPresent(sidebarPosition, forKey: .sidebarPosition)
    try container.encode(sidebarOrderRevision, forKey: .sidebarOrderRevision)
    try container.encodeIfPresent(botId, forKey: .botId)
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
}
