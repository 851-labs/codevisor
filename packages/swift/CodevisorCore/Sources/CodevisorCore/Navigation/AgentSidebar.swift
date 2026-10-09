import Foundation

/// How the sidebar groups top-level agents. Synced across devices
/// (`NavigationStore.sidebarGroupingKey`).
public enum AgentSidebarGrouping: String, Sendable, CaseIterable {
  /// Manual: folders the user made and loose agents, in sidebar order.
  case none
  /// One section per project, in the project order.
  case project
}

/// What an agent row shows about an agent, most urgent first in `rank`.
public enum AgentStatus: Int, Sendable, Comparable {
  case idle = 0
  case unread = 1
  case working = 2
  case waiting = 3
  case errored = 4

  public init(_ session: ChatSession) {
    switch session.sidebarState {
    case .errored: self = .errored
    case .waitingForUser: self = .waiting
    case .inProgress: self = session.actionRequired ? .waiting : .working
    case .unread: self = session.actionRequired ? .waiting : .unread
    case .idle: self = session.actionRequired ? .waiting : .idle
    }
  }

  /// Blocked on an answer or failed: what a parent's rollup surfaces.
  public var isBlocked: Bool { self == .waiting || self == .errored }

  public static func < (lhs: AgentStatus, rhs: AgentStatus) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One of an agent's subagents, flattened to a single level under its root.
public struct AgentSidebarSubagent: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// A chat in its owner's workspace: a tab beside it.
    case chat
    /// A workspace of its own: a tab group in its owner's tab bar.
    case workspace
  }

  /// The chat's id, or the workspace's.
  public let id: UUID
  public let kind: Kind
  /// The workspace that shows it: its owner's for a chat, its own otherwise.
  public let workspaceId: UUID
  public let title: String
  /// The harness its chat runs, for its icon at rest.
  public let harnessId: String?
  public let status: AgentStatus
  /// The subagent that created it, when that is not the row's own agent.
  public let via: String?
}

/// Progress of an agent's subagents: how many finished, and the most urgent
/// state among them (a blocked subagent shows on its root's row).
public struct AgentRollup: Equatable, Sendable {
  public let finished: Int
  public let total: Int
  public let status: AgentStatus
}

/// A top-level agent: an independent workspace and its own subagents.
public struct AgentSidebarRow: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let title: String
  public let serverId: String
  public let projectId: UUID
  /// The worktree it runs in; nil at the project folder.
  public let branch: String?
  /// The harness its own chat runs, for its icon at rest.
  public let harnessId: String?
  public let status: AgentStatus
  public let subagents: [AgentSidebarSubagent]
  /// The agents it owns that have workspaces of their own, nested under it
  /// in the sidebar, each with its own.
  public let children: [AgentSidebarRow]
  public let position: String

  public init(
    id: UUID, title: String, serverId: String, projectId: UUID, branch: String?, harnessId: String? = nil,
    status: AgentStatus, subagents: [AgentSidebarSubagent], children: [AgentSidebarRow] = [], position: String
  ) {
    self.id = id
    self.title = title
    self.harnessId = harnessId
    self.serverId = serverId
    self.projectId = projectId
    self.branch = branch
    self.status = status
    self.subagents = subagents
    self.children = children
    self.position = position
  }

  public var rollup: AgentRollup? {
    guard !subagents.isEmpty else { return nil }
    let finished = subagents.filter { $0.status == .idle || $0.status == .unread }.count
    let status = subagents.map(\.status).max() ?? .idle
    return AgentRollup(finished: finished, total: subagents.count, status: status)
  }
}

extension AgentSidebarRow {
  /// This agent, or one nested anywhere under it.
  public func row(id: UUID) -> AgentSidebarRow? {
    if self.id == id { return self }
    for child in children {
      if let found = child.row(id: id) { return found }
    }
    return nil
  }
}

extension [AgentSidebarNode] {
  /// The row for a workspace anywhere in the sidebar: top level, in a
  /// folder or project, or nested under another agent.
  public func row(id: UUID) -> AgentSidebarRow? {
    for node in self {
      let rows: [AgentSidebarRow] =
        switch node {
        case let .agent(row): [row]
        case let .folder(_, rows), let .project(_, rows): rows
        }
      for row in rows {
        if let found = row.row(id: id) { return found }
      }
    }
    return nil
  }
}

/// One entry of the sidebar's top level.
public enum AgentSidebarNode: Identifiable, Equatable, Sendable {
  case agent(AgentSidebarRow)
  case folder(ServerNavigationFolder, [AgentSidebarRow])
  case project(Project, [AgentSidebarRow])

  public var id: String {
    switch self {
    case let .agent(row): "agent:\(row.id)"
    case let .folder(folder, _): "folder:\(folder.id.lowercased())"
    case let .project(project, _): "project:\(project.serverId):\(project.id)"
    }
  }
}

/// Builds the agent-first sidebar from navigation state. Pure, so every
/// client renders the same structure from the same records.
public enum AgentSidebar {
  public static func build(
    workspaces: [Workspace], sessions: [ChatSession], sessionIndex: [UUID: UUID], projects: [Project],
    records: ServerNavigationRecords, grouping: AgentSidebarGrouping
  ) -> [AgentSidebarNode] {
    let live = workspaces.filter { !$0.isArchived }
    let liveIds = Set(live.map(\.id))
    let chatsByWorkspace = Dictionary(grouping: sessions.filter { sessionIndex[$0.id] != nil }) {
      sessionIndex[$0.id]!
    }
    let ownedBy = Dictionary(grouping: live.filter { $0.parentWorkspaceId.map(liveIds.contains) ?? false }) {
      $0.parentWorkspaceId!
    }
    func row(_ workspace: Workspace, ancestors: Set<UUID> = []) -> AgentSidebarRow {
      let chats = chatsByWorkspace[workspace.id] ?? []
      let roots = rootChats(chats)
      let lineage = ancestors.union([workspace.id])
      let children = (ownedBy[workspace.id] ?? [])
        .filter { !lineage.contains($0.id) }
        .sorted { lhs, rhs in
          (lhs.parentTabPosition ?? "", lhs.id.uuidString) < (rhs.parentTabPosition ?? "", rhs.id.uuidString)
        }
        .map { row($0, ancestors: lineage) }
      return AgentSidebarRow(
        id: workspace.id, title: title(of: workspace, chats: chatsByWorkspace), serverId: workspace.serverId,
        projectId: workspace.projectId,
        branch: workspace.worktreeName, harnessId: homeChat(of: chats)?.harnessId,
        status: roots.map(AgentStatus.init).max() ?? .idle,
        subagents: subagents(of: workspace, chatsByWorkspace: chatsByWorkspace, ownedBy: ownedBy),
        children: children, position: workspace.effectiveSidebarPosition)
    }
    // An owned workspace whose owner is gone (or archived) stands alone.
    let topLevel = live.filter { !($0.parentWorkspaceId.map(liveIds.contains) ?? false) }
      .sorted(by: WorkspaceSidebarOrder.precedes).map { row($0) }
    switch grouping {
    case .none:
      return manual(topLevel, workspaces: live, folders: records.folders.filter { !$0.deleted })
    case .project:
      return byProject(topLevel, projects: projects, settings: records.settings)
    }
  }

  /// What an agent is called: the name the user gave its workspace, else
  /// its own chat's title (a new workspace is only named after its project).
  static func title(of workspace: Workspace, chats: [UUID: [ChatSession]]) -> String {
    guard !workspace.hasCustomName else { return workspace.name }
    return homeChat(of: chats[workspace.id] ?? [])?.title ?? workspace.name
  }

  /// A workspace's first own chat: the agent itself.
  static func homeChat(of chats: [ChatSession]) -> ChatSession? {
    rootChats(chats).min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
  }

  /// A workspace's own chats: the ones no other chat in it created.
  static func rootChats(_ chats: [ChatSession]) -> [ChatSession] {
    let ids = Set(chats.map(\.id))
    return chats.filter { !($0.parentSessionId.map(ids.contains) ?? false) }
  }

  private static func subagents(
    of root: Workspace, chatsByWorkspace: [UUID: [ChatSession]], ownedBy: [UUID: [Workspace]]
  ) -> [AgentSidebarSubagent] {
    var result: [AgentSidebarSubagent] = []
    var visited: Set<UUID> = []
    func visit(_ workspace: Workspace, via: String?) {
      guard visited.insert(workspace.id).inserted else { return }
      let chats = chatsByWorkspace[workspace.id] ?? []
      let ids = Set(chats.map(\.id))
      let roots = Set(rootChats(chats).map(\.id))
      let titles = Dictionary(chats.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
      for chat in chats.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) })
      where !roots.contains(chat.id) {
        let parent = chat.parentSessionId.flatMap { ids.contains($0) ? $0 : nil }
        result.append(
          AgentSidebarSubagent(
            id: chat.id, kind: .chat, workspaceId: workspace.id, title: chat.title, harnessId: chat.harnessId,
            status: AgentStatus(chat),
            via: parent.flatMap { roots.contains($0) ? via : titles[$0] }))
      }
      let owned = (ownedBy[workspace.id] ?? []).sorted { lhs, rhs in
        (lhs.parentTabPosition ?? "", lhs.id.uuidString) < (rhs.parentTabPosition ?? "", rhs.id.uuidString)
      }
      for child in owned {
        let childRoots = rootChats(chatsByWorkspace[child.id] ?? [])
        let name = title(of: child, chats: chatsByWorkspace)
        result.append(
          AgentSidebarSubagent(
            id: child.id, kind: .workspace, workspaceId: child.id, title: name,
            harnessId: homeChat(of: chatsByWorkspace[child.id] ?? [])?.harnessId,
            status: childRoots.map(AgentStatus.init).max() ?? .idle, via: via))
        visit(child, via: name)
      }
    }
    visit(root, via: nil)
    return result
  }

  private static func manual(
    _ rows: [AgentSidebarRow], workspaces: [Workspace], folders: [ServerNavigationFolder]
  ) -> [AgentSidebarNode] {
    let folderIds = Set(folders.compactMap { UUID(uuidString: $0.id) })
    let filing = Dictionary(
      workspaces.compactMap { workspace in workspace.folderId.map { (workspace.id, $0) } },
      uniquingKeysWith: { first, _ in first })
    var filed: [UUID: [AgentSidebarRow]] = [:]
    var nodes: [(position: String, node: AgentSidebarNode)] = []
    for row in rows {
      if let folder = filing[row.id], folderIds.contains(folder) {
        filed[folder, default: []].append(row)
      } else {
        nodes.append((row.position, .agent(row)))
      }
    }
    for folder in folders {
      let rows = UUID(uuidString: folder.id).flatMap { filed[$0] } ?? []
      nodes.append((folder.position, .folder(folder, rows)))
    }
    return nodes.enumerated().sorted { lhs, rhs in
      lhs.element.position == rhs.element.position
        ? lhs.offset < rhs.offset : lhs.element.position < rhs.element.position
    }.map(\.element.node)
  }

  private static func byProject(
    _ rows: [AgentSidebarRow], projects: [Project], settings: [ServerNavigationSetting]
  ) -> [AgentSidebarNode] {
    let order = Dictionary(
      settings.filter { $0.key.hasPrefix(NavigationStore.projectOrderKeyPrefix) }.map {
        (String($0.key.dropFirst(NavigationStore.projectOrderKeyPrefix.count)).lowercased(), $0.value)
      }, uniquingKeysWith: { first, _ in first })
    let grouped = Dictionary(grouping: rows) { $0.projectId }
    let listed = projects.filter { grouped[$0.id] != nil }
    func key(_ project: Project) -> (Int, String, String, String) {
      let position = order[project.id.uuidString.lowercased()]
      return (position == nil ? 1 : 0, position ?? "", project.name.lowercased(), project.serverId)
    }
    return listed.sorted { key($0) < key($1) }.map { .project($0, grouped[$0.id] ?? []) }
  }
}
