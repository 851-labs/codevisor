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
  var sectionSlot: WorkspaceSectionPlacement? = nil
  let rows: [HomeSidebarTabRow]
  var children: [HomeSidebarWorkspace] = []

  var displayName: String { name.isEmpty ? "Workspace" : name }

  var status: HomeSessionStatus { rows.map(\.status).min() ?? .idle }

  var listsTabs: Bool { rows.count > 1 }

  var hasNestedRows: Bool { listsTabs || !children.isEmpty }

  var subtree: [HomeSidebarWorkspace] { [self] + children.flatMap(\.subtree) }

  var primaryRow: HomeSidebarTabRow? {
    rows.first { $0.id == primaryRowId } ?? rows.first
  }

  var workspace: HomeSidebarWorkspaceRef {
    HomeSidebarWorkspaceRef(id: id, serverId: serverId, anchorSessionId: anchorSessionId)
  }

  func placed(in slot: WorkspaceSectionPlacement) -> Self {
    var placed = self
    placed.sectionSlot = slot
    return placed
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
    case browser(favicon: String?)
    case plugin(pluginId: String)
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
  var isMainChat = false
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
  enum Placement: Equatable {
    case pinned
    case list(SidebarWorkspaceGroup.Heading?)
    case archived

    var heading: SidebarWorkspaceGroup.Heading? {
      guard case let .list(heading) = self else { return nil }
      return heading
    }
  }

  struct Group: Identifiable, Equatable {
    let id: String
    let heading: SidebarWorkspaceGroup.Heading?
    let workspaces: [HomeSidebarWorkspace]
  }

  struct SectionGroup: Identifiable, Equatable {
    let section: CustomSection
    let workspaces: [HomeSidebarWorkspace]

    var id: UUID { section.id }
    var collapseID: String { SidebarWorkspaceGroup.customSectionID(section.id) }
  }

  var listTitle = SidebarGrouping.flat.listTitle
  var pinned: [HomeSidebarWorkspace] = []
  var sections: [SectionGroup] = []
  var groups: [Group] = []
  var archived: [HomeSidebarWorkspace] = []
  var archivedCount = 0
  var bots: [HomeSidebarBot] = []
  var archivedBots: [HomeSidebarBot] = []
  var canCreateBots = false

  var showsBots: Bool { !bots.isEmpty || canCreateBots }

  var customSections: [CustomSection] { sections.map(\.section) }

  var listedWorkspaces: [HomeSidebarWorkspace] {
    pinned + sections.flatMap(\.workspaces) + groups.flatMap(\.workspaces)
  }

  var layout: [UUID] {
    bots.flatMap { [$0.id] + $0.children.flatMap(\.subtree).map(\.id) }
      + listedWorkspaces.flatMap(\.subtree).map(\.id)
      + archivedBots.flatMap { [$0.id] + $0.children.flatMap(\.subtree).map(\.id) } + archived.map(\.id)
  }

  private var openWorkspaces: [HomeSidebarWorkspace] {
    bots.compactMap(\.home) + (bots.flatMap(\.children) + listedWorkspaces).flatMap(\.subtree)
  }

  func mode(owning selection: HomeSidebarSelection) -> SidebarMode? {
    switch selection {
    case .bot:
      return .chat
    case let .workspace(id, _):
      if botWorkspaceIDs.contains(id) { return .chat }
      return workspace(id) != nil || archived.contains { $0.id == id } ? .code : nil
    }
  }

  private var botWorkspaceIDs: Set<UUID> {
    let bots = bots + archivedBots
    return Set(bots.compactMap(\.home?.id) + bots.flatMap(\.children).flatMap(\.subtree).map(\.id))
  }

  func bot(_ id: UUID) -> HomeSidebarBot? {
    bots.first { $0.id == id }
  }

  func workspace(_ id: UUID) -> HomeSidebarWorkspace? {
    openWorkspaces.first { $0.id == id }
  }

  func row(_ id: UUID) -> (HomeSidebarTabRow, HomeSidebarWorkspace)? {
    for workspace in openWorkspaces {
      if let row = workspace.rows.first(where: { $0.id == id }) { return (row, workspace) }
    }
    return nil
  }

  static func nesting(
    _ item: WorkspaceSidebarItem, children: [UUID: [WorkspaceSidebarItem]],
    build: (WorkspaceSidebarItem) -> HomeSidebarWorkspace?
  ) -> HomeSidebarWorkspace? {
    guard var workspace = build(item) else { return nil }
    workspace.children = (children[item.id] ?? []).compactMap { nesting($0, children: children, build: build) }
    return workspace
  }

  @MainActor
  static func make(
    listed: [WorkspaceSidebarItem],
    children: [UUID: [WorkspaceSidebarItem]] = [:],
    archived: [WorkspaceSidebarItem],
    preferences: HomeSidebarPreferences,
    projects: [Project],
    defaultServerId: String,
    sections: [CustomSection] = [],
    membership: [UUID: UUID] = [:],
    machineGroup: (String) -> SidebarMachineGroup,
    workspace: (WorkspaceSidebarItem, Placement) -> HomeSidebarWorkspace?
  ) -> HomeSidebarContent {
    let groups = SidebarWorkspaceGroup.groups(
      listed, grouping: preferences.grouping, pinnedIDs: preferences.pinnedIDs, projects: projects,
      defaultServerId: defaultServerId, machineOrder: preferences.machineOrder,
      projectOrder: preferences.projectOrder, sections: sections, membership: membership, machineGroup: machineGroup
    )
    var content = HomeSidebarContent(listTitle: preferences.grouping.listTitle)
    for group in groups {
      let workspaces = group.items.compactMap { item in
        nesting(item, children: children) { workspace($0, placement(of: group)) }
      }
      if group.id == SidebarWorkspaceGroup.pinnedID {
        content.pinned = workspaces.map { $0.placed(in: pinnedPlacement(of: $0.id, membership: membership)) }
      } else if let section = group.customSection {
        content.sections.append(
          SectionGroup(section: section, workspaces: workspaces.map { $0.placed(in: .section(section.id)) }))
      } else {
        content.groups.append(
          Group(id: group.id, heading: group.heading, workspaces: workspaces.map { $0.placed(in: .unsectioned) }))
      }
    }
    let archivedWorkspaces = archived.compactMap { workspace($0, .archived) }
    content.archived = Array(archivedWorkspaces.prefix(preferences.archivedLimit))
    content.archivedCount = archivedWorkspaces.count
    return content
  }

  private static func pinnedPlacement(of id: UUID, membership: [UUID: UUID]) -> WorkspaceSectionPlacement {
    membership[id].map(WorkspaceSectionPlacement.section) ?? .unsectioned
  }

  private static func placement(of group: SidebarWorkspaceGroup) -> Placement {
    group.id == SidebarWorkspaceGroup.pinnedID ? .pinned : .list(group.heading)
  }
}
