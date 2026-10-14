import CodevisorCore
import CodevisorUI
import Foundation
import SwiftUI

extension SidebarView {
  /// The listed workspaces in their saved order, precomputed by the
  /// navigation store and limited here to machines this Mac knows.
  var listedSidebarItems: [WorkspaceSidebarItem] {
    environment.navigationStore.workspaceEntries.sidebar.filter {
      environment.machines.machine(for: $0.serverId) != nil
    }
  }

  /// The chat a workspace routes through: its first routing chat that the
  /// sidebar shows (imported chats only when enabled), else any routing chat
  /// still known to the session list -- a terminal-only workspace routes
  /// through a closed chat that still belongs to it.
  func routingSession(for item: WorkspaceSidebarItem) -> ChatSession? {
    var fallback: ChatSession?
    for id in item.routingChatIds {
      guard let session = list.session(id, serverId: item.serverId) else { continue }
      if session.origin == .codevisor || list.showsImportedSessions { return session }
      if fallback == nil { fallback = session }
    }
    return fallback
  }

  /// A listed workspace's current value with its routing chat. Nil once the
  /// workspace is gone.
  func listItem(for item: WorkspaceSidebarItem) -> SidebarWorkspaceListItem? {
    guard let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace,
      !workspace.isArchived
    else { return nil }
    return SidebarWorkspaceListItem(workspace: workspace, routingSession: routingSession(for: item))
  }

  /// The pinned workspaces first, in their own group, then the rest split by
  /// the sidebar's grouping. Reads only the precomputed list (each item
  /// carries its machine and project), the project list, and the machines.
  var workspaceGroups: [SidebarWorkspaceGroup] {
    let pinned = Set(pinnedWorkspaceIDs)
    let listed = listedSidebarItems
    let pinnedItems = listed.filter { pinned.contains($0.id.uuidString) }
    // A section of its own under a plain heading, not a collapsible group.
    let pinnedGroup = SidebarWorkspaceGroup(id: SidebarWorkspaceGroup.pinnedID, heading: nil, items: pinnedItems)
    let rest = groupedWorkspaces(listed.filter { !pinned.contains($0.id.uuidString) })
    return pinnedItems.isEmpty ? rest : [pinnedGroup] + rest
  }

  /// Whether a workspace sits in the Pinned group.
  func isPinned(_ workspace: Workspace) -> Bool {
    pinnedWorkspaceIDs.contains(workspace.id.uuidString)
  }

  func togglePin(_ workspace: Workspace) {
    let id = workspace.id.uuidString
    withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
      if pinnedWorkspaceIDs.contains(id) {
        pinnedWorkspaceIDs.removeAll { $0 == id }
      } else {
        pinnedWorkspaceIDs.append(id)
      }
    }
  }

  private func groupedWorkspaces(_ items: [WorkspaceSidebarItem]) -> [SidebarWorkspaceGroup] {
    switch grouping {
    case .flat:
      return [SidebarWorkspaceGroup(id: "all", heading: nil, items: items)]
    case .machine:
      return SidebarWorkspaceGroup.grouping(items, by: { "machine:\($0.serverId)" }) { item in
        let machine = environment.machines.machine(for: item.serverId)
        return SidebarWorkspaceGroup.Heading(
          title: machineName(forServer: item.serverId) ?? "Unknown Machine",
          systemImage: machine.map(EntitySystemSymbol.machine) ?? "questionmark.circle",
          newChatTarget: machine.map { NewChatTarget(machine: $0.id) }
        )
      }
    case .project:
      // One folder per logical project: every machine's record of the same
      // repository, folded by `ProjectGroup` as Settings › Projects and the
      // composer's picker fold them. Its rows name their machine instead.
      let records = Dictionary(
        list.projects.map { ("\($0.serverId)/\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
      let groups = Dictionary(
        ProjectGroup.grouping(list.projects).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      // A workspace whose project record hasn't arrived yet stays on its own.
      func groupID(_ item: WorkspaceSidebarItem) -> String {
        records["\(item.serverId)/\(item.projectId)"].map(ProjectGroup.groupID(for:))
          ?? "project|\(item.serverId)|\(item.projectId.uuidString)"
      }
      return SidebarWorkspaceGroup.grouping(items, by: { "project:\(groupID($0))" }) { item in
        let group = groups[groupID(item)]
        return SidebarWorkspaceGroup.Heading(
          title: group?.name ?? "Unknown Project",
          systemImage: EntitySystemSymbol.projectList,
          newChatTarget: newChatTarget(in: group, fallback: item)
        )
      }
    }
  }

  /// Where a project folder's New Chat starts one: the project's checkout
  /// on this Mac's default machine when it has one, else the machine of the
  /// folder's first workspace.
  private func newChatTarget(in group: ProjectGroup?, fallback item: WorkspaceSidebarItem) -> NewChatTarget {
    if let member = group?.member(on: environment.defaultComposerServerId) {
      return NewChatTarget(member)
    }
    return NewChatTarget(serverId: item.serverId, projectId: item.projectId)
  }

  /// Whether a group's rows are showing. The flat sidebar's group always is.
  func isExpanded(_ group: SidebarWorkspaceGroup) -> Bool {
    group.heading == nil || !collapsedGroupIDs.contains(group.id)
  }

  /// Whether a group's rows are on screen: its section heading and the
  /// group itself are both expanded.
  func isShowing(_ group: SidebarWorkspaceGroup) -> Bool {
    group.id == SidebarWorkspaceGroup.pinnedID ? pinnedExpanded : listExpanded && isExpanded(group)
  }

  func toggleGroup(_ group: SidebarWorkspaceGroup) {
    if collapsedGroupIDs.contains(group.id) {
      collapsedGroupIDs.removeAll { $0 == group.id }
    } else {
      collapsedGroupIDs.append(group.id)
    }
  }

  /// Every workspace row on screen, resolved, in the order the sidebar
  /// shows them (collapsed groups' rows are hidden). For actions that need
  /// the whole list (keyboard stepping) -- never read from a view body.
  var listedWorkspaceItems: [SidebarWorkspaceListItem] {
    workspaceGroups.filter(isShowing).flatMap(\.items).compactMap(listItem(for:))
  }
}
