import Foundation
import Observation

@MainActor
@Observable
public final class WorkspaceEntry: Identifiable {
  public let id: UUID
  public private(set) var workspace: Workspace?
  public private(set) var generation: UInt64 = 0

  init(id: UUID, workspace: Workspace?) {
    self.id = id
    self.workspace = workspace
  }

  func update(_ workspace: Workspace?) {
    guard workspace != self.workspace else { return }
    self.workspace = workspace
    generation &+= 1
  }
}

public struct WorkspaceSidebarItem: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let serverId: String
  public let projectId: UUID
  public let routingChatIds: [UUID]
  public let parent: WorkspaceParentLink?
  public let isBotHome: Bool

  public init(
    id: UUID, serverId: String, projectId: UUID, routingChatIds: [UUID], parent: WorkspaceParentLink? = nil,
    isBotHome: Bool = false
  ) {
    self.id = id
    self.serverId = serverId
    self.projectId = projectId
    self.routingChatIds = routingChatIds
    self.parent = parent
    self.isBotHome = isBotHome
  }

  public var parentWorkspaceId: UUID? { parent?.workspaceId }
}

extension NavigationWorkspaces {
  public var botHomeIds: Set<UUID> {
    Set((sidebar + archived).filter(\.isBotHome).map(\.id))
  }
}

@MainActor
@Observable
public final class NavigationWorkspaces {
  @ObservationIgnored private var entries: [UUID: WorkspaceEntry] = [:]
  public private(set) var sidebar: [WorkspaceSidebarItem] = []
  public private(set) var archived: [WorkspaceSidebarItem] = []
  @ObservationIgnored private var sidebarIndex: [UUID: UUID] = [:]
  @ObservationIgnored private var parentIndex: [UUID: WorkspaceParentLink] = [:]
  @ObservationIgnored private var botProjectIndex: Set<UUID> = []
  @ObservationIgnored var lookup: (UUID) -> Workspace? = { _ in nil }

  init() {}

  public func entry(_ id: UUID) -> WorkspaceEntry {
    if let existing = entries[id] { return existing }
    let created = WorkspaceEntry(id: id, workspace: lookup(id))
    entries[id] = created
    return created
  }

  func apply(_ projection: NavigationProjection, changed: Set<UUID>, removed: Set<UUID>) {
    for id in changed { entries[id]?.update(projection.workspacesById[id]) }
    for id in removed { entries[id]?.update(nil) }
    let parents = Self.parentLinks(in: projection)
    let botProjects = Self.botProjectIds(in: projection)
    guard
      !changed.isEmpty || !removed.isEmpty || projection.sessionIndex != sidebarIndex || parents != parentIndex
        || botProjects != botProjectIndex
    else { return }
    sidebarIndex = projection.sessionIndex
    parentIndex = parents
    botProjectIndex = botProjects
    let live = Self.live(from: projection, parents: parents)
    if live != sidebar { sidebar = live }
    let nextArchived = Self.archived(from: projection)
    if nextArchived != archived { archived = nextArchived }
  }

  static func archived(from projection: NavigationProjection) -> [WorkspaceSidebarItem] {
    let botProjects = botProjectIds(in: projection)
    return projection.workspaces.filter(\.isArchived)
      .sorted { lhs, rhs in
        let lhsArchivedAt = lhs.archivedAt ?? lhs.createdAt
        let rhsArchivedAt = rhs.archivedAt ?? rhs.createdAt
        if lhsArchivedAt != rhsArchivedAt { return lhsArchivedAt > rhsArchivedAt }
        return lhs.id.uuidString < rhs.id.uuidString
      }
      .map { workspace in
        WorkspaceSidebarItem(
          id: workspace.id, serverId: workspace.serverId, projectId: workspace.projectId,
          routingChatIds: workspace.mainFirstChatSessionIds,
          isBotHome: botProjects.contains(workspace.projectId))
      }
  }

  static func botProjectIds(in projection: NavigationProjection) -> Set<UUID> {
    Set(projection.projects.filter(\.isBot).map(\.id))
  }

  func update(_ workspace: Workspace, sessionWorkspace: (UUID) -> UUID?) {
    entries[workspace.id]?.update(workspace)
    let routed = workspace.mainFirstChatSessionIds.filter { sessionWorkspace($0) == workspace.id }
    func refreshed(_ current: WorkspaceSidebarItem) -> WorkspaceSidebarItem {
      WorkspaceSidebarItem(
        id: workspace.id, serverId: workspace.serverId, projectId: workspace.projectId,
        routingChatIds: routed.isEmpty ? current.routingChatIds : routed, parent: current.parent,
        isBotHome: current.isBotHome)
    }
    if let index = sidebar.firstIndex(where: { $0.id == workspace.id }) {
      let item = refreshed(sidebar[index])
      if sidebar[index] != item { sidebar[index] = item }
    }
  }

  static func live(
    from projection: NavigationProjection, parents: [UUID: WorkspaceParentLink]
  ) -> [WorkspaceSidebarItem] {
    var indexedChats: [UUID: UUID] = [:]
    for session in projection.sessions {
      guard let workspaceId = projection.sessionIndex[session.id], indexedChats[workspaceId] == nil else { continue }
      indexedChats[workspaceId] = session.id
    }
    let live = projection.workspaces.filter { !$0.isArchived }
      .map { (workspace: $0, position: $0.effectiveSidebarPosition) }
      .sorted { lhs, rhs in
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        if lhs.workspace.serverId != rhs.workspace.serverId { return lhs.workspace.serverId < rhs.workspace.serverId }
        return lhs.workspace.id.uuidString < rhs.workspace.id.uuidString
      }
    let botProjects = botProjectIds(in: projection)
    return live.compactMap { entry in
      let workspace = entry.workspace
      let routed = workspace.mainFirstChatSessionIds.filter { projection.sessionIndex[$0] == workspace.id }
      guard workspace.chatSessionIds.isEmpty || !routed.isEmpty else { return nil }
      let fallback = indexedChats[workspace.id].map { [$0] } ?? []
      return WorkspaceSidebarItem(
        id: workspace.id, serverId: workspace.serverId, projectId: workspace.projectId,
        routingChatIds: routed.isEmpty ? fallback : routed, parent: parents[workspace.id],
        isBotHome: botProjects.contains(workspace.projectId))
    }
  }

  static func parentLinks(in projection: NavigationProjection) -> [UUID: WorkspaceParentLink] {
    var parents: [UUID: WorkspaceParentLink] = [:]
    for session in projection.sessions {
      guard let source = session.parentAgent,
        let workspaceId = projection.sessionIndex[session.id],
        let parentId = projection.sessionIndex[source.agentId], parentId != workspaceId,
        projection.workspacesById[workspaceId] != nil,
        projection.workspacesById[parentId]?.hostServerId == source.machineId,
        parents[workspaceId].map({ session.createdAt < $0.linkedAt }) ?? true
      else { continue }
      parents[workspaceId] = WorkspaceParentLink(
        workspaceId: parentId, linkedAt: session.createdAt,
        isQuiet: session.createdByAgent != nil)
    }
    return parents
  }

  func remove(_ id: UUID) {
    entries[id]?.update(nil)
  }
}
