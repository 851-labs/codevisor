import CodevisorClient
import Foundation

/// A folder, or a project when grouped by project: a row of the Folders
/// list that discloses the workspaces in it.
public struct HomeSidebarGroup: Sendable {
  public let id: String
  public let title: String
  public let rows: [AgentSidebarRow]
  public var folder: ServerNavigationFolder?
  public var projectId: UUID?
}

/// The root list's two lists, as Notes has Folders and Notes: the folders
/// (or projects), each disclosing its workspaces, then the workspaces in
/// no folder. A workspace with workspaces nested under it discloses those.
public enum HomeListSection: Hashable, Sendable {
  case groups
  case workspaces
}

public enum HomeListItem: Hashable, Sendable {
  case group(String)
  case workspace(UUID)
}

/// The rows the list shows, and where each sits.
public struct HomeListModel: Sendable {
  public struct Placement: Sendable {
    public let row: AgentSidebarRow
    /// The workspace it's nested under, if any.
    public let owner: UUID?
    /// The folder (or project) it's listed in, if any.
    public let groupId: String?
  }

  public let grouping: AgentSidebarGrouping
  public let groups: [HomeSidebarGroup]
  /// Workspaces in no folder.
  public let loose: [AgentSidebarRow]
  public let placements: [UUID: Placement]

  public init(nodes: [AgentSidebarNode], grouping: AgentSidebarGrouping) {
    self.grouping = grouping
    var groups: [HomeSidebarGroup] = []
    var loose: [AgentSidebarRow] = []
    var placements: [UUID: Placement] = [:]
    func place(_ row: AgentSidebarRow, owner: UUID?, groupId: String?) {
      placements[row.id] = Placement(row: row, owner: owner, groupId: groupId)
      for child in row.children { place(child, owner: row.id, groupId: groupId) }
    }
    for node in nodes {
      switch node {
      case let .agent(row):
        loose.append(row)
        place(row, owner: nil, groupId: nil)
      case let .folder(folder, rows):
        groups.append(HomeSidebarGroup(id: folder.id, title: folder.name, rows: rows, folder: folder))
        for row in rows { place(row, owner: nil, groupId: folder.id) }
      case let .project(project, rows):
        let id = "\(project.serverId):\(project.id)"
        groups.append(HomeSidebarGroup(id: id, title: project.name, rows: rows, projectId: project.id))
        for row in rows { place(row, owner: nil, groupId: id) }
      }
    }
    self.groups = groups
    self.loose = loose
    self.placements = placements
  }

  public func group(_ id: String) -> HomeSidebarGroup? { groups.first { $0.id == id } }

  /// The item a row is listed under: the workspace it's nested in, else its
  /// folder (or project); nil at the top of the Workspaces list.
  public func parent(of item: HomeListItem) -> HomeListItem? {
    guard case let .workspace(id) = item, let placement = placements[id] else { return nil }
    if let owner = placement.owner { return .workspace(owner) }
    return placement.groupId.map(HomeListItem.group)
  }

  /// Where a row sorts among its siblings: a folder's place, or a
  /// workspace's when it isn't nested.
  public func position(of item: HomeListItem) -> String? {
    switch item {
    case let .group(id): group(id)?.folder?.position
    case let .workspace(id): placements[id].flatMap { $0.owner == nil ? $0.row.position : nil }
    }
  }

  public func isWithin(_ item: HomeListItem, _ ancestor: HomeListItem) -> Bool {
    var current: HomeListItem? = item
    while let next = current {
      if next == ancestor { return true }
      current = parent(of: next)
    }
    return false
  }
}

/// Where a dragged row would land, and so what dropping it does.
public enum HomeListDrop: Equatable, Sendable {
  /// Onto a folder's row: filed at the end of that folder.
  case intoGroup(String)
  /// Among a folder's (or project's) workspaces, between two of them.
  case inGroup(String, after: String?, before: String?)
  /// Among the workspaces in no folder.
  case loose(after: String?, before: String?)
  /// Among the workspaces nested under the same one, at this index.
  case nested(owner: UUID, index: Int, siblings: [UUID])
  /// A folder among the folders.
  case folder(after: String?, before: String?)
  /// A project among the projects, at this index.
  case project(index: Int, projects: [UUID])

  /// Where `dragged` lands inserted at `index` among `visible`, the
  /// section's rows as listed (the dragged row and what it discloses left
  /// out). Nil where it can't go: a folder among workspaces, a workspace
  /// at the top of the Folders list or nested under another workspace,
  /// one into another project.
  public static func resolve(
    _ dragged: HomeListItem, in section: HomeListSection, visible: [HomeListItem], at index: Int,
    model: HomeListModel
  ) -> HomeListDrop? {
    let index = min(max(0, index), visible.count)
    let previous = index > 0 ? visible[index - 1] : nil
    let next = index < visible.count ? visible[index] : nil
    func between(_ level: HomeListItem?) -> (String?, String?) {
      let isSibling = { (item: HomeListItem) in model.parent(of: item) == level }
      let lower = visible.prefix(index).last(where: isSibling).flatMap(model.position)
      let upper = visible.dropFirst(index).first(where: isSibling).flatMap(model.position)
      return (lower, upper)
    }
    switch dragged {
    case let .group(id):
      guard section == .groups, next.map({ if case .group = $0 { true } else { false } }) ?? true else { return nil }
      if model.group(id)?.projectId != nil {
        let projects = visible.compactMap { item -> UUID? in
          if case let .group(other) = item { model.group(other)?.projectId } else { nil }
        }
        let before = visible.prefix(index).filter { if case .group = $0 { true } else { false } }.count
        return .project(index: before, projects: projects)
      }
      let (lower, upper) = between(nil)
      return .folder(after: lower, before: upper)
    case let .workspace(id):
      guard let placement = model.placements[id] else { return nil }
      // Before a workspace it joins that workspace's siblings; at the end
      // of a list, the last group's (or the loose list's) end.
      let level: HomeListItem?
      if let next, case .workspace = next {
        level = model.parent(of: next)
      } else if section == .workspaces {
        level = nil
      } else if let previous, case .workspace = previous {
        var top = previous
        while let parent = model.parent(of: top), case .workspace = parent { top = parent }
        level = model.parent(of: top)
      } else {
        return nil
      }
      switch level {
      case nil:
        guard section == .workspaces, model.grouping == .none else { return nil }
        let (lower, upper) = between(nil)
        return .loose(after: lower, before: upper)
      case let .group(groupId):
        if model.grouping == .project, groupId != placement.groupId { return nil }
        let (lower, upper) = between(.group(groupId))
        return .inGroup(groupId, after: lower, before: upper)
      case let .workspace(owner):
        guard placement.owner == owner, let siblings = model.placements[owner]?.row.children else { return nil }
        let isSibling = { (item: HomeListItem) in model.parent(of: item) == .workspace(owner) }
        return .nested(
          owner: owner, index: visible.prefix(index).filter(isSibling).count,
          siblings: siblings.map(\.id).filter { $0 != id })
      }
    }
  }

  /// Dropped onto `target`'s row: a workspace into a folder it isn't in.
  public static func onto(_ target: HomeListItem, dragging dragged: HomeListItem, model: HomeListModel) -> HomeListDrop?
  {
    guard case let .group(groupId) = target, case let .workspace(id) = dragged, model.grouping == .none,
      let placement = model.placements[id], placement.groupId != groupId || placement.owner != nil
    else { return nil }
    return .intoGroup(groupId)
  }
}
