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
          systemImage: machine.map(EntitySystemSymbol.machine) ?? "questionmark.circle"
        )
      }
    case .project:
      let names = Dictionary(
        list.projects.map { ("\($0.serverId)/\($0.id)", $0.name) }, uniquingKeysWith: { first, _ in first })
      // A project names its machine only when there is more than one to
      // tell apart; its rows already omit the machine.
      let namesMachine = environment.machines.allMachines.count > 1
      return SidebarWorkspaceGroup.grouping(items, by: { "project:\($0.serverId)/\($0.projectId)" }) { item in
        SidebarWorkspaceGroup.Heading(
          title: names["\(item.serverId)/\(item.projectId)"] ?? "Unknown Project",
          subtitle: namesMachine ? machineName(forServer: item.serverId) : nil,
          systemImage: EntitySystemSymbol.projectList,
          newChatTarget: NewChatTarget(serverId: item.serverId, projectId: item.projectId)
        )
      }
    }
  }

  /// Whether a group's rows are showing. The flat sidebar's group always is.
  func isExpanded(_ group: SidebarWorkspaceGroup) -> Bool {
    group.heading == nil || !collapsedGroupIDs.contains(group.id)
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
    workspaceGroups.filter(isExpanded).flatMap(\.items).compactMap(listItem(for:))
  }
}
