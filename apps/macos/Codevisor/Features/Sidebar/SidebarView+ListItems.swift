import CodevisorCore
import CodevisorUI
import Foundation
import SwiftUI

extension SidebarView {
  var botHomeWorkspaceIDs: Set<UUID> {
    botsEnabled ? Set(environment.bots.bots.map(\.workspaceId)) : []
  }

  var listedSidebarItems: [WorkspaceSidebarItem] {
    let botHomes = botHomeWorkspaceIDs
    return environment.navigationStore.workspaceEntries.sidebar.filter {
      environment.machines.machine(for: $0.serverId) != nil && !botHomes.contains($0.id)
    }
  }

  func routingSession(for item: WorkspaceSidebarItem) -> ChatSession? {
    rowContent.routingSession(for: item)
  }

  func listItem(for item: WorkspaceSidebarItem) -> SidebarWorkspaceListItem? {
    rowContent.listItem(for: item)
  }

  var workspaceGroups: [SidebarWorkspaceGroup] {
    workspaceGroups(listedSidebarItems)
  }

  func workspaceGroups(_ items: [WorkspaceSidebarItem]) -> [SidebarWorkspaceGroup] {
    SidebarWorkspaceGroup.groups(
      items, grouping: grouping, pinnedIDs: pinnedWorkspaceIDs, projects: list.projects,
      defaultServerId: environment.defaultComposerServerId, machineOrder: machineOrder, machineKey: machineKey,
      projectOrder: projectOrder
    ) { serverId in
      let machine = environment.machines.machine(for: serverId)
      return SidebarWorkspaceGroup.Heading(
        title: machineName(forServer: serverId) ?? "Unknown Machine",
        systemImage: machine?.icon.systemImage ?? "questionmark.circle",
        newChatTarget: machine.map { NewChatTarget(machine: $0.id) }
      )
    }
  }

  func isPinned(_ workspace: Workspace) -> Bool {
    pinnedWorkspaceIDs.contains(workspace.id.uuidString)
  }

  func togglePin(_ workspace: Workspace) {
    let id = workspace.id.uuidString
    if pinnedWorkspaceIDs.contains(id) {
      pinnedWorkspaceIDs.removeAll { $0 == id }
    } else {
      pinnedWorkspaceIDs.append(id)
    }
  }

  func toggleGroup(_ id: String) {
    if collapsedGroupIDs.contains(id) {
      collapsedGroupIDs.removeAll { $0 == id }
    } else {
      collapsedGroupIDs.append(id)
    }
  }

  var selectedWorkspaceID: UUID? {
    switch selection {
    case let .session(_, sessionId): environment.workspaces.workspaceId(forSession: sessionId)
    case let .workspace(_, id), let .archivedWorkspace(_, id): id
    case .bot, .newChat, .none: nil
    }
  }

  var routedWorkspace: (serverId: String, id: UUID)? {
    switch selection {
    case let .session(serverId, sessionId):
      environment.workspaces.workspaceId(forSession: sessionId).map { (serverId, $0) }
    case let .workspace(serverId, id): (serverId, id)
    case .archivedWorkspace, .bot, .newChat, .none: nil
    }
  }
}
