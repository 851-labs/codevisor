//  A workspace: the persistence root for everything in a window's content
//  area. It owns browser-style tabs whose contents are split trees (one pane
//  per leaf), plus the workspace-wide ⌘J bottom panel. Chats are
//  REFERENCES to sessions (the server owns transcripts and
//  lifecycle); a workspace can host many, each anchored to a directory under
//  the workspace's root.

import Foundation

/// One browser-style workspace tab. Its content is an independent split
/// layout and `activeLeafId` records which split receives keyboard commands
/// and supplies the tab's title/icon.
public struct WorkspaceTab: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  /// User-pinned label for this layout. Nil keeps the browser-style title
  /// following whichever split is active inside the tab.
  public var customTitle: String?
  public var root: SplitNode
  public var activeLeafId: UUID

  public init(
    id: UUID = UUID(),
    customTitle: String? = nil,
    root: SplitNode,
    activeLeafId: UUID? = nil
  ) {
    self.id = id
    self.customTitle = customTitle
    self.root = root
    self.activeLeafId =
      activeLeafId.flatMap { root.group(id: $0) != nil ? $0 : nil }
      ?? root.allGroups.first?.id
      ?? UUID()
  }

  private enum CodingKeys: String, CodingKey { case id, customTitle, root, activeLeafId }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
    let decodedRoot = try container.decode(SplitNode.self, forKey: .root)
    root = decodedRoot
    let decoded = try container.decodeIfPresent(UUID.self, forKey: .activeLeafId)
    activeLeafId =
      decoded.flatMap { decodedRoot.group(id: $0) != nil ? $0 : nil }
      ?? decodedRoot.allGroups.first?.id
      ?? UUID()
  }
}

public struct Workspace: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  /// Display name. Automatic names begin with the project name and may
  /// follow a newly-created worktree; an explicit rename pins the name.
  public var name: String
  public var hasCustomName: Bool
  /// The workspace's one, authoritative working directory (project checkout
  /// or worktree), fixed at creation. Every chat/terminal in the workspace
  /// runs at this root. Nil when the backing session hasn't resolved its
  /// directory yet.
  public var rootDirectory: String?
  /// The git worktree this workspace lives in, when it was created with the
  /// "start in a new worktree" option. Nil means the workspace runs at the
  /// project root. New sessions in the workspace are stamped with this name
  /// so the server derives their cwd. Decoded leniently: payloads written
  /// before this field existed load as nil.
  public var worktreeName: String?
  /// The machine the workspace's sessions and shells live on.
  public let serverId: String
  public let projectId: UUID
  /// Browser-style tabs across the center area. Each tab owns a split tree
  /// whose leaf groups contain exactly one pane.
  public var centerTabs: [WorkspaceTab]
  public var selectedCenterTabId: UUID
  /// The ⌘J bottom panel.
  public var bottomGroup: PaneGroupState
  public var createdAt: Date
  /// Archived workspaces leave the sidebar (their chats archive with
  /// them) but keep their layout — opening an archived chat revives the
  /// workspace intact. Decoded leniently: payloads written before this
  /// field existed load as not archived.
  public var isArchived: Bool
  /// True once this workspace identity has appeared in an authoritative
  /// server snapshot. This lets a later snapshot remove a remotely deleted
  /// workspace without mistaking an older, client-only workspace for a
  /// deletion. Decoded leniently for existing local data.
  public var isServerSynced: Bool

  private enum CodingKeys: String, CodingKey {
    case id, name, hasCustomName, rootDirectory, worktreeName, serverId
    case projectId, centerTabs, selectedCenterTabId, bottomGroup, createdAt, isArchived
    case isServerSynced
    /// Version-1 workspaces stored one tree whose leaves were tab groups.
    case centerTree
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    hasCustomName = try container.decode(Bool.self, forKey: .hasCustomName)
    rootDirectory = try container.decodeIfPresent(String.self, forKey: .rootDirectory)
    worktreeName = try container.decodeIfPresent(String.self, forKey: .worktreeName)
    serverId = try container.decode(String.self, forKey: .serverId)
    projectId = try container.decode(UUID.self, forKey: .projectId)
    if let decodedTabs = try container.decodeIfPresent([WorkspaceTab].self, forKey: .centerTabs) {
      if decodedTabs.isEmpty {
        let replacement = WorkspaceTab(root: .leaf(PaneGroupState()))
        centerTabs = [replacement]
        selectedCenterTabId = replacement.id
      } else {
        centerTabs = decodedTabs
        let decodedSelection = try container.decodeIfPresent(
          UUID.self, forKey: .selectedCenterTabId
        )
        selectedCenterTabId =
          decodedSelection.flatMap { candidate in
            decodedTabs.contains { $0.id == candidate } ? candidate : nil
          } ?? decodedTabs[0].id
      }
    } else {
      let legacy = try container.decode(SplitNode.self, forKey: .centerTree)
      centerTabs = Self.migrateLegacyCenterTree(legacy)
      selectedCenterTabId = centerTabs[0].id
    }
    bottomGroup = try container.decode(PaneGroupState.self, forKey: .bottomGroup)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    isServerSynced = try container.decodeIfPresent(Bool.self, forKey: .isServerSynced) ?? false
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
    try container.encode(bottomGroup, forKey: .bottomGroup)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(isArchived, forKey: .isArchived)
    try container.encode(isServerSynced, forKey: .isServerSynced)
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
    bottomGroup: PaneGroupState,
    createdAt: Date = Date(),
    isArchived: Bool = false,
    isServerSynced: Bool = false
  ) {
    self.id = id
    self.name = name
    self.hasCustomName = hasCustomName
    self.rootDirectory = rootDirectory
    self.worktreeName = worktreeName
    self.serverId = serverId
    self.projectId = projectId
    let tabs = Self.migrateLegacyCenterTree(centerTree)
    self.centerTabs = tabs
    self.selectedCenterTabId = tabs[0].id
    self.bottomGroup = bottomGroup
    self.createdAt = createdAt
    self.isArchived = isArchived
    self.isServerSynced = isServerSynced
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
    bottomGroup: PaneGroupState,
    createdAt: Date = Date(),
    isArchived: Bool = false,
    isServerSynced: Bool = false
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
    self.bottomGroup = bottomGroup
    self.createdAt = createdAt
    self.isArchived = isArchived
    self.isServerSynced = isServerSynced
  }

  /// Transitional convenience for layout code: reads/writes the selected
  /// top tab's tree. New code should use `centerTabs` when it needs to see
  /// across tabs.
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

  public func tabId(containingPane paneId: UUID) -> UUID? {
    centerTabs.first { $0.root.groupId(containingPane: paneId) != nil }?.id
  }

  public func tabId(containingChat sessionId: UUID) -> UUID? {
    centerTabs.first { $0.root.groupId(containingChat: sessionId) != nil }?.id
  }

  /// The selected pane in a specific split leaf, across every top tab.
  /// Keyboard/header split actions use the targeted leaf rather than the
  /// workspace's sidebar-routed chat when choosing an inheritance source.
  public func selectedPane(inLeaf leafId: UUID) -> PaneDescriptorState? {
    centerTabs.lazy.compactMap { $0.root.group(id: leafId)?.selectedPane }.first
  }

  /// The one chat this workspace currently puts in front of the user: the
  /// selected pane of the active split leaf of the selected center tab,
  /// when that pane is a chat. This is the focus signal for read state —
  /// merely remaining mounted in another split is insufficient.
  ///
  /// `activeLeafId` is the window's live active leaf; nil falls back to the
  /// tab's persisted value. First-responder focus routes through leaf
  /// activation + sidebar selection before reaching here, so
  /// pane-selection-level focus is the source of truth.
  public func focusedChatId(activeLeafId: UUID?) -> UUID? {
    guard let selectedTab = selectedCenterTab else { return nil }
    let resolvedActiveLeafId: UUID
    if let activeLeafId, selectedTab.root.group(id: activeLeafId) != nil {
      resolvedActiveLeafId = activeLeafId
    } else {
      resolvedActiveLeafId = selectedTab.activeLeafId
    }
    guard let pane = selectedTab.root.group(id: resolvedActiveLeafId)?.selectedPane,
      pane.kind == .chat
    else { return nil }
    return pane.chatSessionId
  }

  /// The pane that owns a chat session reference, if it is still open.
  public func pane(containingChat sessionId: UUID) -> PaneDescriptorState? {
    centerTabs.lazy
      .flatMap { $0.root.allGroups }
      .flatMap(\.state.panes)
      .first { $0.kind == .chat && $0.chatSessionId == sessionId }
  }

  /// Replaces an existing center pane without changing its tab/split slot,
  /// or appends it as a new top tab when this device has not placed the pane
  /// yet. New Tab promotion uses this to keep one pane identity while its
  /// renderer changes from placeholder to chat/terminal.
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
      panes: [pane], selectedPaneId: pane.id, isVisible: true
    )
    let tab = WorkspaceTab(root: .leaf(state))
    centerTabs.append(tab)
    if selecting { selectedCenterTabId = tab.id }
    return tab.id
  }

  /// Session ids of every chat pane in the workspace, reading order.
  public var chatSessionIds: [UUID] {
    centerTabs.flatMap { tab in
      tab.root.allGroups.flatMap { group in
        group.state.panes.compactMap { $0.kind == .chat ? $0.chatSessionId : nil }
      }
    }
  }

  /// Inverts the version-1 `split → tab groups` hierarchy. The selected
  /// pane from every old group keeps the visible split topology; hidden
  /// siblings become independent top tabs in deterministic reading order.
  private static func migrateLegacyCenterTree(_ legacy: SplitNode) -> [WorkspaceTab] {
    var overflow: [PaneDescriptorState] = []

    func selectedOnly(_ node: SplitNode) -> SplitNode {
      switch node {
      case let .group(id, state):
        let selected =
          state.selectedPane
          ?? state.panes.first
          ?? PaneDescriptorState(
            id: UUID(), kind: .newTab, name: "New Tab", terminalKey: UUID().uuidString
          )
        overflow.append(contentsOf: state.panes.filter { $0.id != selected.id })
        var single = state
        single.panes = [selected]
        single.selectedPaneId = selected.id
        single.isVisible = true
        return .group(id: id, state: single)
      case let .split(orientation, children):
        return .split(
          orientation: orientation,
          children: children.map {
            SplitChild(fraction: $0.fraction, node: selectedOnly($0.node))
          })
      }
    }

    let visible = WorkspaceTab(root: selectedOnly(legacy))
    let lifted = overflow.map { pane -> WorkspaceTab in
      var state = PaneGroupState()
      state.panes = [pane]
      state.selectedPaneId = pane.id
      state.isVisible = true
      return WorkspaceTab(root: .leaf(state))
    }
    return [visible] + lifted
  }
}
