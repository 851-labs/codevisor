import CodevisorCore
import Foundation

public enum SidebarGrouping: String, CaseIterable, Codable, Sendable {
  case flat
  case project
  case machine

  public static let preferenceKey = "sidebar.grouping"
  public static let collapsedPreferenceKey = "sidebar.collapsedGroups"

  public var title: String {
    switch self {
    case .flat: "None"
    case .project: "Project"
    case .machine: "Machine"
    }
  }

  public var listTitle: String {
    switch self {
    case .flat: "Workspaces"
    case .project: "Projects"
    case .machine: "Machines"
    }
  }
}

public enum SidebarPreferenceKey {
  public static let pinnedWorkspaces = "sidebar.pinnedWorkspaces"
  public static let pinnedExpanded = "sidebar.pinnedExpanded"
  public static let listExpanded = "sidebar.listExpanded"
  public static let archivedExpanded = "sidebar.archivedExpanded"
  public static let botsExpanded = "sidebar.botsExpanded"
  public static let collapsedBotSections = "sidebar.collapsedBotSections"
  public static let machineOrder = "sidebar.machineOrder"
  public static let projectOrder = "sidebar.projectOrder"

  public static let synced = Set(
    [SidebarGrouping.preferenceKey, pinnedWorkspaces, machineOrder, projectOrder] + SidebarRowDetail.preferenceKeys)
}

public let sidebarArchivedPageSize = 10

public struct NewChatTarget: Hashable, Sendable {
  public let serverId: String
  public let projectId: UUID?

  public init(serverId: String, projectId: UUID?) {
    self.serverId = serverId
    self.projectId = projectId
  }

  public init(machine serverId: String) {
    self.init(serverId: serverId, projectId: nil)
  }

  public init(_ project: Project) {
    self.init(serverId: project.serverId, projectId: project.id)
  }
}

public struct SidebarWorkspaceGroup: Identifiable, Equatable {
  public struct Heading: Equatable {
    public let title: String
    public let icon: SidebarGroupIcon
    public var newChatTarget: NewChatTarget?
    public var namesMachine = false

    public init(title: String, icon: SidebarGroupIcon, newChatTarget: NewChatTarget? = nil) {
      self.title = title
      self.icon = icon
      self.newChatTarget = newChatTarget
    }
  }

  public static let pinnedID = "pinned"

  public let id: String
  public let heading: Heading?
  public let items: [WorkspaceSidebarItem]

  public init(id: String, heading: Heading?, items: [WorkspaceSidebarItem]) {
    self.id = id
    self.heading = heading
    self.items = items
  }

  public static func groups(
    _ items: [WorkspaceSidebarItem],
    grouping: SidebarGrouping,
    pinnedIDs: [String],
    projects: [Project],
    defaultServerId: String,
    machineOrder: [String] = [],
    projectOrder: [String] = [],
    machineGroup: (String) -> SidebarMachineGroup
  ) -> [SidebarWorkspaceGroup] {
    let pinned = Set(pinnedIDs)
    let pinnedItems = items.filter { pinned.contains($0.id.uuidString) }
    let rest = items.filter { !pinned.contains($0.id.uuidString) }
    let grouped: [SidebarWorkspaceGroup] =
      switch grouping {
      case .flat:
        [SidebarWorkspaceGroup(id: "all", heading: nil, items: rest)]
      case .machine:
        machineGroups(rest, order: machineOrder, machineGroup: machineGroup)
      case .project:
        Self.ordered(
          projectGroups(rest, projects: projects, defaultServerId: defaultServerId), by: projectOrder,
          key: projectKey)
      }
    guard !pinnedItems.isEmpty else { return grouped }
    return [SidebarWorkspaceGroup(id: pinnedID, heading: nil, items: pinnedItems)] + grouped
  }

  private static func machineGroups(
    _ items: [WorkspaceSidebarItem], order: [String], machineGroup: (String) -> SidebarMachineGroup
  ) -> [SidebarWorkspaceGroup] {
    let groups = grouping(items, by: { "machine:\(machineGroup($0.serverId).key)" }) {
      machineGroup($0.serverId).heading
    }
    return ordered(groups.map(\.namingSharedMachine), by: order, key: { machineGroup($0.items[0].serverId).orderKey })
  }

  private var namingSharedMachine: SidebarWorkspaceGroup {
    guard var heading else { return self }
    heading.namesMachine = Set(items.map(\.serverId)).count == 1
    return SidebarWorkspaceGroup(id: id, heading: heading, items: items)
  }

  private static func projectGroups(
    _ items: [WorkspaceSidebarItem], projects: [Project], defaultServerId: String
  ) -> [SidebarWorkspaceGroup] {
    let records = Dictionary(
      projects.map { ("\($0.serverId)/\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
    let groups = Dictionary(
      ProjectGroup.grouping(projects).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func groupID(_ item: WorkspaceSidebarItem) -> String {
      records["\(item.serverId)/\(item.projectId)"].map(ProjectGroup.groupID(for:))
        ?? "project|\(item.serverId)|\(item.projectId.uuidString)"
    }
    return grouping(items, by: { "project:\(groupID($0))" }) { item in
      let group = groups[groupID(item)]
      let target =
        group?.member(on: defaultServerId).map(NewChatTarget.init)
        ?? NewChatTarget(serverId: item.serverId, projectId: item.projectId)
      return Heading(
        title: group?.name ?? "Unknown Project",
        icon: .system(EntitySystemSymbol.projectList),
        newChatTarget: target
      )
    }
  }

  public static func projectKey(_ group: SidebarWorkspaceGroup) -> String {
    let repoPrefix = "project:repo|"
    guard group.id.hasPrefix(repoPrefix) else { return group.items.first?.projectId.uuidString ?? group.id }
    return String(group.id.dropFirst("project:".count))
  }

  public static func savedOrder(
    _ saved: [String], moving key: String, to index: Int, among shown: [String]
  ) -> [String] {
    var order: [String] = []
    for entry in saved + shown where !order.contains(entry) { order.append(entry) }
    return ListReorder.moving(key, to: index, within: shown, in: order)
  }

  static func ordered(
    _ groups: [SidebarWorkspaceGroup], by order: [String], key: (SidebarWorkspaceGroup) -> String
  ) -> [SidebarWorkspaceGroup] {
    guard !order.isEmpty else { return groups }
    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    let ranks: [Int] = groups.map { rank[key($0)] ?? .max }
    let positions = groups.indices.sorted { ranks[$0] != ranks[$1] ? ranks[$0] < ranks[$1] : $0 < $1 }
    return positions.map { groups[$0] }
  }

  static func grouping(
    _ items: [WorkspaceSidebarItem],
    by key: (WorkspaceSidebarItem) -> String,
    heading: (WorkspaceSidebarItem) -> Heading
  ) -> [SidebarWorkspaceGroup] {
    var order: [String] = []
    var members: [String: [WorkspaceSidebarItem]] = [:]
    for item in items {
      let id = key(item)
      if members[id] == nil { order.append(id) }
      members[id, default: []].append(item)
    }
    return order.compactMap { id in
      guard let items = members[id], let first = items.first else { return nil }
      return SidebarWorkspaceGroup(id: id, heading: heading(first), items: items)
    }
  }
}

public enum SidebarRowSubtitle {
  public static func make(
    details: [SidebarRowDetail], title: String, projectName: String?, branch: String?, worktreeName: String?,
    groupNamesProject: Bool
  ) -> String? {
    var parts: [String] = []
    for detail in SidebarRowDetail.subtitleDetails where details.contains(detail) {
      let part: String? =
        switch detail {
        case .project: groupNamesProject ? nil : projectName
        case .branch: branch
        case .worktree: worktreeName == title ? nil : worktreeName
        default: nil
        }
      guard let part, !part.isEmpty, !parts.contains(part) else { continue }
      parts.append(part)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
