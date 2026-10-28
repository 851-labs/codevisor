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
  public let botId: UUID?
  public let botMachineId: String?
  public let parentWorkspaceId: UUID?

  public init(
    id: UUID, serverId: String, projectId: UUID, routingChatIds: [UUID], botId: UUID? = nil,
    botMachineId: String? = nil, parentWorkspaceId: UUID? = nil
  ) {
    self.id = id
    self.serverId = serverId
    self.projectId = projectId
    self.routingChatIds = routingChatIds
    self.botId = botId
    self.botMachineId = botMachineId
    self.parentWorkspaceId = parentWorkspaceId
  }

  public var belongsToSameMachineBot: Bool { botId != nil && botMachineId == nil }
}

@MainActor
@Observable
public final class NavigationWorkspaces {
  @ObservationIgnored private var entries: [UUID: WorkspaceEntry] = [:]
  public private(set) var sidebar: [WorkspaceSidebarItem] = []
  public private(set) var archived: [WorkspaceSidebarItem] = []
  public private(set) var botChildren: [UUID: [WorkspaceSidebarItem]] = [:]
  @ObservationIgnored private var sidebarIndex: [UUID: UUID] = [:]
  @ObservationIgnored private var parentIndex: [UUID: UUID] = [:]
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
    let parents = Self.parentWorkspaceIds(in: projection)
    guard !changed.isEmpty || !removed.isEmpty || projection.sessionIndex != sidebarIndex || parents != parentIndex
    else { return }
    sidebarIndex = projection.sessionIndex
    parentIndex = parents
    let live = Self.live(from: projection, parents: parents)
    if live != sidebar { sidebar = live }
    let nextChildren = Dictionary(grouping: live.filter { $0.botId != nil }) { $0.botId! }
    if nextChildren != botChildren { botChildren = nextChildren }
    let nextArchived = Self.archived(from: projection)
    if nextArchived != archived { archived = nextArchived }
  }

  static func archived(from projection: NavigationProjection) -> [WorkspaceSidebarItem] {
    projection.workspaces.filter(\.isArchived)
      .sorted { lhs, rhs in
        let lhsArchivedAt = lhs.archivedAt ?? lhs.createdAt
        let rhsArchivedAt = rhs.archivedAt ?? rhs.createdAt
        if lhsArchivedAt != rhsArchivedAt { return lhsArchivedAt > rhsArchivedAt }
        return lhs.id.uuidString < rhs.id.uuidString
      }
      .map { workspace in
        WorkspaceSidebarItem(
          id: workspace.id, serverId: workspace.serverId, projectId: workspace.projectId,
          routingChatIds: workspace.chatSessionIds, botId: workspace.botId, botMachineId: workspace.botMachineId)
      }
  }

  func update(_ workspace: Workspace, sessionWorkspace: (UUID) -> UUID?) {
    entries[workspace.id]?.update(workspace)
    let routed = workspace.chatSessionIds.filter { sessionWorkspace($0) == workspace.id }
    func refreshed(_ current: WorkspaceSidebarItem) -> WorkspaceSidebarItem {
      WorkspaceSidebarItem(
        id: workspace.id, serverId: workspace.serverId, projectId: workspace.projectId,
        routingChatIds: routed.isEmpty ? current.routingChatIds : routed, botId: current.botId,
        botMachineId: current.botMachineId, parentWorkspaceId: current.parentWorkspaceId)
    }
    if let index = sidebar.firstIndex(where: { $0.id == workspace.id }) {
      let item = refreshed(sidebar[index])
      if sidebar[index] != item { sidebar[index] = item }
    }
    if let botId = workspace.botId,
      let index = botChildren[botId]?.firstIndex(where: { $0.id == workspace.id }),
      let current = botChildren[botId]?[index]
    {
      let item = refreshed(current)
      if current != item { botChildren[botId]?[index] = item }
    }
  }

  static func live(from projection: NavigationProjection, parents: [UUID: UUID]) -> [WorkspaceSidebarItem] {
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
    return live.compactMap { entry in
      let workspace = entry.workspace
      let chats = workspace.chatSessionIds
      let routed = chats.filter { projection.sessionIndex[$0] == workspace.id }
      guard chats.isEmpty || !routed.isEmpty else { return nil }
      let fallback = indexedChats[workspace.id].map { [$0] } ?? []
      return WorkspaceSidebarItem(
        id: workspace.id, serverId: workspace.serverId, projectId: workspace.projectId,
        routingChatIds: routed.isEmpty ? fallback : routed, botId: workspace.botId,
        botMachineId: workspace.botMachineId, parentWorkspaceId: parents[workspace.id])
    }
  }

  static func parentWorkspaceIds(in projection: NavigationProjection) -> [UUID: UUID] {
    var parents: [UUID: (workspaceId: UUID, startedAt: Date)] = [:]
    for session in projection.sessions {
      guard let parentSessionId = session.parentSessionId.flatMap(UUID.init(uuidString:)),
        let workspaceId = projection.sessionIndex[session.id],
        let parentId = projection.sessionIndex[parentSessionId], parentId != workspaceId,
        let workspace = projection.workspacesById[workspaceId],
        projection.workspacesById[parentId]?.serverId == workspace.serverId,
        parents[workspaceId].map({ session.createdAt < $0.startedAt }) ?? true
      else { continue }
      parents[workspaceId] = (parentId, session.createdAt)
    }
    return parents.mapValues(\.workspaceId)
  }

  func remove(_ id: UUID) {
    entries[id]?.update(nil)
  }
}
