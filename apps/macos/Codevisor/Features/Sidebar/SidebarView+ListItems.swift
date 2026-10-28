import CodevisorCore
import CodevisorUI
import Foundation
import SwiftUI

extension SidebarView {
  var workspaceListing: SidebarWorkspaceListing {
    SidebarWorkspaceListing(
      environment: environment, botsEnabled: botsEnabled, grouping: grouping, pinnedIDs: pinnedWorkspaceIDs,
      machineOrder: machineOrder, projectOrder: projectOrder)
  }

  var listedSidebarItems: [WorkspaceSidebarItem] {
    workspaceListing.listedItems
  }

  func routingSession(for item: WorkspaceSidebarItem) -> ChatSession? {
    rowContent.routingSession(for: item)
  }

  func listItem(for item: WorkspaceSidebarItem) -> SidebarWorkspaceListItem? {
    rowContent.listItem(for: item)
  }

  var workspaceGroups: [SidebarWorkspaceGroup] {
    let listing = workspaceListing
    return listing.groups(of: listing.tree.roots)
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

  func toggleChildren(of id: UUID) {
    toggleGroup(SidebarRows.childrenGroupID(id))
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
