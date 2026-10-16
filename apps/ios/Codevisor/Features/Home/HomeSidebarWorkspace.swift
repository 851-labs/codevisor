import CodevisorCore
import CodevisorUI
import Foundation
import UIKit

struct HomeSidebarWorkspace: Identifiable, Equatable {
  let id: UUID
  let serverId: String
  let name: String
  let anchorSessionId: UUID?
  var subtitle: String? = nil
  var machine: HomeSidebarRowMachine? = nil
  var pullRequest: ServerGitPullRequest? = nil
  var leadingRow: HomeSidebarTabRow? = nil
  var primaryRowId: UUID? = nil
  var isPinned = false
  var isArchived = false
  let rows: [HomeSidebarTabRow]

  var displayName: String { name.isEmpty ? "Workspace" : name }

  var status: HomeSessionStatus { rows.map(\.status).min() ?? .idle }

  var listsTabs: Bool { rows.count > 1 }

  var primaryRow: HomeSidebarTabRow? {
    rows.first { $0.id == primaryRowId } ?? rows.first
  }

  var workspace: HomeSidebarWorkspaceRef {
    HomeSidebarWorkspaceRef(id: id, serverId: serverId, anchorSessionId: anchorSessionId)
  }
}

struct HomeSidebarRowMachine: Equatable {
  let name: String
  let systemImage: String
}

struct HomeSidebarWorkspaceRef: Equatable {
  let id: UUID
  let serverId: String
  let anchorSessionId: UUID?
}

struct HomeSidebarTabRow: Identifiable, Equatable {
  enum Icon: Equatable {
    case chat(harnessId: String, fallbackSymbolName: String)
    case terminal
    case browser(favicon: UIImage?)
    case plugin(pluginId: String, paneType: String?)
    case document
    case screenSharing
    case simulator
    case review
    case newTab
  }

  let id: UUID
  let title: String
  let icon: Icon
  let status: HomeSessionStatus
  let chatSessionId: UUID?
  let renamableTabId: UUID?
  var tabId: UUID? = nil
}

struct HomeSidebarPreferences: Equatable {
  var grouping = SidebarGrouping.flat
  var pinnedIDs: [String] = []
  var machineOrder: [String] = []
  var projectOrder: [String] = []
  var rowDetails = SidebarRowDetail.defaults
  var archivedLimit = sidebarArchivedPageSize
}

struct HomeSidebarContent: Equatable {
  enum Placement {
    case pinned
    case list
    case archived
  }

  struct Group: Identifiable, Equatable {
    let id: String
    let heading: SidebarWorkspaceGroup.Heading?
    let workspaces: [HomeSidebarWorkspace]
  }

  var listTitle = SidebarGrouping.flat.listTitle
  var pinned: [HomeSidebarWorkspace] = []
  var groups: [Group] = []
  var archived: [HomeSidebarWorkspace] = []
  var archivedCount = 0

  var layout: [UUID] {
    (pinned + groups.flatMap(\.workspaces) + archived).map(\.id)
  }

  func workspace(_ id: UUID) -> HomeSidebarWorkspace? {
    pinned.first { $0.id == id }
      ?? groups.lazy.flatMap(\.workspaces).first { $0.id == id }
  }

  func row(_ id: UUID) -> (HomeSidebarTabRow, HomeSidebarWorkspace)? {
    for workspace in pinned + groups.flatMap(\.workspaces) {
      if let row = workspace.rows.first(where: { $0.id == id }) { return (row, workspace) }
    }
    return nil
  }

  @MainActor
  static func make(
    listed: [WorkspaceSidebarItem],
    archived: [WorkspaceSidebarItem],
    preferences: HomeSidebarPreferences,
    projects: [Project],
    defaultServerId: String,
    machineKey: (String) -> String = { $0 },
    machineHeading: (String) -> SidebarWorkspaceGroup.Heading,
    workspace: (WorkspaceSidebarItem, Placement) -> HomeSidebarWorkspace?
  ) -> HomeSidebarContent {
    let groups = SidebarWorkspaceGroup.groups(
      listed, grouping: preferences.grouping, pinnedIDs: preferences.pinnedIDs, projects: projects,
      defaultServerId: defaultServerId, machineOrder: preferences.machineOrder, machineKey: machineKey,
      projectOrder: preferences.projectOrder, machineHeading: machineHeading
    )
    var content = HomeSidebarContent(listTitle: preferences.grouping.listTitle)
    for group in groups {
      if group.id == SidebarWorkspaceGroup.pinnedID {
        content.pinned = group.items.compactMap { workspace($0, .pinned) }
      } else {
        content.groups.append(
          Group(id: group.id, heading: group.heading, workspaces: group.items.compactMap { workspace($0, .list) })
        )
      }
    }
    let archivedWorkspaces = archived.compactMap { workspace($0, .archived) }
    content.archived = Array(archivedWorkspaces.prefix(preferences.archivedLimit))
    content.archivedCount = archivedWorkspaces.count
    return content
  }
}
