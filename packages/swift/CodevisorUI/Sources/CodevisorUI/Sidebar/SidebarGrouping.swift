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

  public static let synced: Set<String> = [
    SidebarGrouping.preferenceKey, SidebarRowDetail.preferenceKey, pinnedWorkspaces,
  ]
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
    public let systemImage: String
    public var newChatTarget: NewChatTarget?

    public init(title: String, systemImage: String, newChatTarget: NewChatTarget? = nil) {
      self.title = title
      self.systemImage = systemImage
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
    machineHeading: (String) -> Heading
  ) -> [SidebarWorkspaceGroup] {
    let pinned = Set(pinnedIDs)
    let pinnedItems = items.filter { pinned.contains($0.id.uuidString) }
    let rest = items.filter { !pinned.contains($0.id.uuidString) }
    let grouped: [SidebarWorkspaceGroup] =
      switch grouping {
      case .flat:
        [SidebarWorkspaceGroup(id: "all", heading: nil, items: rest)]
      case .machine:
        Self.grouping(rest, by: { "machine:\($0.serverId)" }) { machineHeading($0.serverId) }
      case .project:
        projectGroups(rest, projects: projects, defaultServerId: defaultServerId)
      }
    guard !pinnedItems.isEmpty else { return grouped }
    return [SidebarWorkspaceGroup(id: pinnedID, heading: nil, items: pinnedItems)] + grouped
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
        systemImage: EntitySystemSymbol.projectList,
        newChatTarget: target
      )
    }
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
    details: [SidebarRowDetail], projectName: String?, branch: String?, groupNamesProject: Bool
  ) -> String? {
    let parts = SidebarRowDetail.subtitleDetails.compactMap { detail -> String? in
      guard details.contains(detail) else { return nil }
      let part: String? =
        switch detail {
        case .project: groupNamesProject ? nil : projectName
        case .branch: branch
        default: nil
        }
      return part?.isEmpty == false ? part : nil
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
