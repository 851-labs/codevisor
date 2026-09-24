import Foundation
import Observation

/// One workspace, observable on its own.
///
/// A view that shows a workspace reads its entry, so it re-renders only when
/// that workspace changes -- not when a chat elsewhere is marked read or
/// another device edits some other workspace. Entries are stable for a
/// workspace's lifetime, so SwiftUI identity never churns.
@MainActor
@Observable
public final class WorkspaceEntry: Identifiable {
  public let id: UUID
  /// Nil once the workspace is gone (or before it is known).
  public private(set) var workspace: Workspace?
  /// Advances each time `workspace` changes; handy as an `onChange` value.
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

/// A workspace as the sidebar lists it: which one, on which machine, and the
/// chats that route into it (the first one anchors the workspace's route).
public struct WorkspaceSidebarItem: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let serverId: String
  public let routingChatIds: [UUID]
}

/// The per-workspace entries for everything navigation shows.
///
/// Updated from `NavigationStore` rebuilds (only the workspaces a rebuild
/// changed) and synchronously from layout saves, so a tab click updates exactly
/// one entry within the same transaction.
@MainActor
@Observable
public final class NavigationWorkspaces {
  @ObservationIgnored private var entries: [UUID: WorkspaceEntry] = [:]
  /// The sidebar's workspaces in display order: live (not archived) ones,
  /// sorted by their shared position, without automatic workspaces whose
  /// chats all moved elsewhere. Recomputed only when a workspace changes, so
  /// a mark-read or another machine's unrelated event never touches it.
  public private(set) var sidebar: [WorkspaceSidebarItem] = []
  /// The chat → workspace index the sidebar was last built from; a chat
  /// moving between workspaces changes routing without changing any
  /// workspace.
  @ObservationIgnored private var sidebarIndex: [UUID: UUID] = [:]
  /// Where a new entry reads its current value; set once the repository is
  /// attached.
  @ObservationIgnored var lookup: (UUID) -> Workspace? = { _ in nil }

  init() {}

  /// The entry for a workspace, created on first use and never replaced.
  public func entry(_ id: UUID) -> WorkspaceEntry {
    if let existing = entries[id] { return existing }
    let created = WorkspaceEntry(id: id, workspace: lookup(id))
    entries[id] = created
    return created
  }

  func apply(_ projection: NavigationProjection, changed: Set<UUID>, removed: Set<UUID>) {
    for id in changed { entries[id]?.update(projection.workspacesById[id]) }
    for id in removed { entries[id]?.update(nil) }
    guard !changed.isEmpty || !removed.isEmpty || projection.sessionIndex != sidebarIndex else { return }
    sidebarIndex = projection.sessionIndex
    let next = Self.sidebar(from: projection)
    if next != sidebar { sidebar = next }
  }

  /// A layout save: only this workspace's routing chats can change.
  func update(_ workspace: Workspace, sessionWorkspace: (UUID) -> UUID?) {
    entries[workspace.id]?.update(workspace)
    guard let index = sidebar.firstIndex(where: { $0.id == workspace.id }) else { return }
    let routed = workspace.chatSessionIds.filter { sessionWorkspace($0) == workspace.id }
    let item = WorkspaceSidebarItem(
      id: workspace.id, serverId: workspace.serverId,
      routingChatIds: routed.isEmpty ? sidebar[index].routingChatIds : routed)
    if sidebar[index] != item { sidebar[index] = item }
  }

  static func sidebar(from projection: NavigationProjection) -> [WorkspaceSidebarItem] {
    // Any chat the index places in a workspace can route to it -- including a
    // closed one, which is how a terminal-only workspace stays reachable.
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
      // An automatic workspace whose chats all moved elsewhere is superseded.
      // Empty workspaces have no chats and stay listed.
      guard chats.isEmpty || !routed.isEmpty else { return nil }
      let fallback = indexedChats[workspace.id].map { [$0] } ?? []
      return WorkspaceSidebarItem(
        id: workspace.id, serverId: workspace.serverId, routingChatIds: routed.isEmpty ? fallback : routed)
    }
  }

  func remove(_ id: UUID) {
    entries[id]?.update(nil)
  }
}
