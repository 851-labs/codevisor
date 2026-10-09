import Foundation

/// A subagent with its own workspace, shown as a tab group in its owner's
/// tab bar: its chat first, then its other tabs.
public struct TabStripGroup: Equatable, Sendable {
  public let workspaceId: UUID
  public let title: String
  public let status: AgentStatus
  public let collapsed: Bool
  public let tabs: [WorkspaceTab]

  public init(workspaceId: UUID, title: String, status: AgentStatus, collapsed: Bool, tabs: [WorkspaceTab]) {
    self.workspaceId = workspaceId
    self.title = title
    self.status = status
    self.collapsed = collapsed
    self.tabs = tabs
  }
}

/// One entry of a workspace's tab bar: one of its tabs, or a subagent's
/// tab group.
public enum TabStripEntry: Identifiable, Equatable, Sendable {
  case tab(WorkspaceTab)
  case group(TabStripGroup)

  public var id: UUID {
    switch self {
    case let .tab(tab): tab.id
    case let .group(group): group.workspaceId
    }
  }
}

/// The tab bar shared by every client: a workspace's tabs (in the shared tab
/// order) with its subagents' tab groups placed among them by their own keys,
/// which live in the same key space as the tabs' pane keys.
public enum TabStrip {
  /// A key change that puts the strip in the order the user wants.
  public enum Move: Equatable, Sendable {
    case pane(paneId: UUID, position: String)
    case group(workspaceId: UUID, position: String)
  }

  /// `tabs` in their shared order, with each group placed at its key. Tabs
  /// without a key (a pane the server hasn't listed yet) keep their slot
  /// relative to the tab before them.
  public static func entries(
    tabs: [WorkspaceTab], positions: [UUID: String], groups: [(group: TabStripGroup, position: String?)]
  ) -> [TabStripEntry] {
    var result: [TabStripEntry] = []
    let placed = groups.sorted {
      ($0.position ?? "~", $0.group.workspaceId.uuidString) < ($1.position ?? "~", $1.group.workspaceId.uuidString)
    }
    var pending = placed[...]
    for tab in tabs {
      if let anchor = anchor(of: tab, positions: positions) {
        while let next = pending.first, let position = next.position, position < anchor {
          result.append(.group(next.group))
          pending = pending.dropFirst()
        }
      }
      result.append(.tab(tab))
    }
    result += pending.map { .group($0.group) }
    return result
  }

  /// The fewest key changes that make `entries` (the order the user wants)
  /// the order every device sorts to. Entries already in order keep their
  /// keys; each moved one gets keys between its kept neighbours.
  public static func moves(
    for entries: [TabStripEntry], positions: [UUID: String], groupPositions: [UUID: String]
  ) -> [Move] {
    let keyed: [(entry: TabStripEntry, keys: [(Move.Kind, String)])] = entries.compactMap { entry in
      switch entry {
      case let .tab(tab):
        let keys = SharedTabOrder.paneIds(of: tab).compactMap { id in positions[id].map { (Move.Kind.pane(id), $0) } }
        return keys.isEmpty ? nil : (entry, keys)
      case let .group(group):
        guard let key = groupPositions[group.workspaceId] else { return nil }
        return (entry, [(.group(group.workspaceId), key)])
      }
    }
    let anchors = keyed.map { $0.keys.map(\.1).min()! }
    let kept = SharedTabOrder.longestIncreasing(anchors)
    var moves: [Move] = []
    var lower: String?
    for index in keyed.indices {
      let upper = (index + 1..<anchors.count).first(where: kept.contains).map { anchors[$0] }
      if kept.contains(index) {
        let largest = keyed[index].keys.map(\.1).max()!
        lower = upper.map { largest >= $0 } == true ? anchors[index] : largest
        continue
      }
      for (kind, _) in keyed[index].keys {
        guard let position = WorkspacePosition.between(lower, upper, id: kind.id) else { continue }
        moves.append(kind.move(to: position))
        lower = position
      }
    }
    return moves
  }

  /// The chat that is the workspace's own: the first one no other chat in
  /// it created. Its tab is the agent itself, so it can't be closed.
  public static func homeChatId(of workspace: Workspace, sessions: [ChatSession]) -> UUID? {
    let ids = Set(workspace.chatSessionIds)
    let chats = sessions.filter { ids.contains($0.id) }
    let byId = Set(chats.map(\.id))
    return chats.filter { !($0.parentSessionId.map(byId.contains) ?? false) }
      .min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }?.id
  }

  /// Whether a tab can be closed: every tab except the one with the home chat.
  public static func isClosable(_ tab: WorkspaceTab, homeChatId: UUID?) -> Bool {
    guard let homeChatId else { return true }
    return !tab.root.allGroups.contains { group in group.state.panes.contains { $0.chatSessionId == homeChatId } }
  }

  private static func anchor(of tab: WorkspaceTab, positions: [UUID: String]) -> String? {
    SharedTabOrder.paneIds(of: tab).compactMap { positions[$0] }.min()
  }
}

extension TabStrip.Move {
  fileprivate enum Kind {
    case pane(UUID)
    case group(UUID)

    var id: UUID {
      switch self {
      case let .pane(id), let .group(id): id
      }
    }

    func move(to position: String) -> TabStrip.Move {
      switch self {
      case let .pane(id): .pane(paneId: id, position: position)
      case let .group(id): .group(workspaceId: id, position: position)
      }
    }
  }
}
