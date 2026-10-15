import CodevisorCore
import CodevisorUI
import Foundation
import SwiftUI

extension SidebarView {
  var listedSidebarItems: [WorkspaceSidebarItem] {
    environment.navigationStore.workspaceEntries.sidebar.filter {
      environment.machines.machine(for: $0.serverId) != nil
    }
  }

  func routingSession(for item: WorkspaceSidebarItem) -> ChatSession? {
    var fallback: ChatSession?
    for id in item.routingChatIds {
      guard let session = list.session(id, serverId: item.serverId) else { continue }
      if session.origin == .codevisor || list.showsImportedSessions { return session }
      if fallback == nil { fallback = session }
    }
    return fallback
  }

  func listItem(for item: WorkspaceSidebarItem) -> SidebarWorkspaceListItem? {
    guard let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace,
      !workspace.isArchived
    else { return nil }
    return SidebarWorkspaceListItem(workspace: workspace, routingSession: routingSession(for: item))
  }

  var workspaceGroups: [SidebarWorkspaceGroup] {
    let pinned = Set(pinnedWorkspaceIDs)
    let listed = listedSidebarItems
    let pinnedItems = listed.filter { pinned.contains($0.id.uuidString) }
    let pinnedGroup = SidebarWorkspaceGroup(id: SidebarWorkspaceGroup.pinnedID, heading: nil, items: pinnedItems)
    let rest = groupedWorkspaces(listed.filter { !pinned.contains($0.id.uuidString) })
    return pinnedItems.isEmpty ? rest : [pinnedGroup] + rest
  }

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
          systemImage: machine.map(SidebarRowMachine.systemImage(for:)) ?? "questionmark.circle",
          newChatTarget: machine.map { NewChatTarget(machine: $0.id) }
        )
      }
    case .project:
      let records = Dictionary(
        list.projects.map { ("\($0.serverId)/\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
      let groups = Dictionary(
        ProjectGroup.grouping(list.projects).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

  private func newChatTarget(in group: ProjectGroup?, fallback item: WorkspaceSidebarItem) -> NewChatTarget {
    if let member = group?.member(on: environment.defaultComposerServerId) {
      return NewChatTarget(member)
    }
    return NewChatTarget(serverId: item.serverId, projectId: item.projectId)
  }

  func isExpanded(_ group: SidebarWorkspaceGroup) -> Bool {
    group.heading == nil || !collapsedGroupIDs.contains(group.id)
  }

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

  var selectedWorkspaceID: UUID? {
    switch selection {
    case let .session(_, sessionId): environment.workspaces.workspaceId(forSession: sessionId)
    case let .workspace(_, id), let .archivedWorkspace(_, id): id
    case .newChat, .none: nil
    }
  }

  func visibleItems(of group: SidebarWorkspaceGroup) -> [WorkspaceSidebarItem] {
    if isShowing(group) { return group.items }
    guard let selectedWorkspaceID else { return [] }
    return group.items.filter { $0.id == selectedWorkspaceID }
  }

  var listedWorkspaceItems: [SidebarWorkspaceListItem] {
    workspaceGroups.flatMap(visibleItems(of:)).compactMap(listItem(for:))
  }
}
