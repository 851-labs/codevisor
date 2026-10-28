import CodevisorCore
import Foundation

public enum SidebarSection: Hashable, Sendable {
  case pinned
  case list
  case archived
}

public enum SidebarRowID: Hashable, Sendable {
  case section(SidebarSection)
  case group(String)
  case workspace(UUID)
  case showMoreArchived
}

public struct SidebarRow: Identifiable, Equatable {
  public enum Placement: Hashable, Sendable {
    case pinned
    case group(String)
    case archived
  }

  public enum Kind: Equatable {
    case section(SidebarSection, isExpanded: Bool)
    case group(id: String, heading: SidebarWorkspaceGroup.Heading, isExpanded: Bool)
    case workspace(WorkspaceSidebarItem, Placement)
    case showMoreArchived
  }

  public struct Disclosure: Equatable, Sendable {
    public let childCount: Int
    public let isExpanded: Bool

    public init(childCount: Int, isExpanded: Bool) {
      self.childCount = childCount
      self.isExpanded = isExpanded
    }
  }

  public let kind: Kind
  public let depth: Int
  public let nesting: Int
  public let parentID: UUID?
  public let disclosure: Disclosure?

  public init(
    _ kind: Kind, depth: Int = 0, nesting: Int = 0, parentID: UUID? = nil, disclosure: Disclosure? = nil
  ) {
    self.kind = kind
    self.depth = depth
    self.nesting = nesting
    self.parentID = parentID
    self.disclosure = disclosure
  }

  public var section: SidebarSection {
    switch kind {
    case let .section(section, _): section
    case .group: .list
    case .showMoreArchived: .archived
    case let .workspace(_, placement):
      switch placement {
      case .pinned: .pinned
      case .group: .list
      case .archived: .archived
      }
    }
  }

  public var id: SidebarRowID {
    switch kind {
    case let .section(section, _): .section(section)
    case let .group(id, _, _): .group(id)
    case let .workspace(item, _): .workspace(item.id)
    case .showMoreArchived: .showMoreArchived
    }
  }
}

public enum SidebarRows {
  public struct Expansion: Equatable, Sendable {
    public var pinned: Bool
    public var list: Bool
    public var archived: Bool
    public var collapsedGroupIDs: Set<String>
    public var expandedWorkspaceIDs: Set<UUID>

    public init(
      pinned: Bool = true, list: Bool = true, archived: Bool = false, collapsedGroupIDs: Set<String> = [],
      expandedWorkspaceIDs: Set<UUID> = []
    ) {
      self.pinned = pinned
      self.list = list
      self.archived = archived
      self.collapsedGroupIDs = collapsedGroupIDs
      self.expandedWorkspaceIDs = expandedWorkspaceIDs
    }
  }

  public struct State: Equatable {
    public var groups: [SidebarWorkspaceGroup]
    public var children: [UUID: [WorkspaceSidebarItem]]
    public var archived: [WorkspaceSidebarItem]
    public var archivedVisibleCount: Int
    public var expansion: Expansion
    public var selectedWorkspaceID: UUID?

    public init(
      groups: [SidebarWorkspaceGroup], children: [UUID: [WorkspaceSidebarItem]] = [:],
      archived: [WorkspaceSidebarItem] = [], archivedVisibleCount: Int = sidebarArchivedPageSize,
      expansion: Expansion = Expansion(), selectedWorkspaceID: UUID? = nil
    ) {
      self.groups = groups
      self.children = children
      self.archived = archived
      self.archivedVisibleCount = archivedVisibleCount
      self.expansion = expansion
      self.selectedWorkspaceID = selectedWorkspaceID
    }
  }

  public static func derive(_ state: State) -> [SidebarRow] {
    var rows: [SidebarRow] = []
    let expansion = state.expansion

    func appendWorkspace(
      _ item: WorkspaceSidebarItem, _ placement: SidebarRow.Placement, depth: Int, nesting: Int = 0,
      parentID: UUID? = nil, showing: Bool
    ) {
      let children = state.children[item.id] ?? []
      let isExpanded = expansion.expandedWorkspaceIDs.contains(item.id)
      if showing || item.id == state.selectedWorkspaceID {
        let disclosure =
          children.isEmpty ? nil : SidebarRow.Disclosure(childCount: children.count, isExpanded: isExpanded)
        rows.append(
          SidebarRow(
            .workspace(item, placement), depth: depth, nesting: nesting, parentID: parentID, disclosure: disclosure))
      }
      for child in children {
        appendWorkspace(
          child, placement, depth: depth + 1, nesting: nesting + 1, parentID: item.id, showing: showing && isExpanded)
      }
    }

    if let pinned = state.groups.first(where: { $0.id == SidebarWorkspaceGroup.pinnedID }) {
      rows.append(SidebarRow(.section(.pinned, isExpanded: expansion.pinned)))
      for item in pinned.items {
        appendWorkspace(item, .pinned, depth: 0, showing: expansion.pinned)
      }
    }

    rows.append(SidebarRow(.section(.list, isExpanded: expansion.list)))
    for group in state.groups where group.id != SidebarWorkspaceGroup.pinnedID {
      let isExpanded = group.heading == nil || !expansion.collapsedGroupIDs.contains(group.id)
      let showsHeading = group.heading != nil && expansion.list
      if let heading = group.heading, showsHeading {
        rows.append(SidebarRow(.group(id: group.id, heading: heading, isExpanded: isExpanded)))
      }
      for item in group.items {
        appendWorkspace(item, .group(group.id), depth: showsHeading ? 1 : 0, showing: expansion.list && isExpanded)
      }
    }

    return rows + archivedRows(state)
  }

  private static func archivedRows(_ state: State) -> [SidebarRow] {
    guard !state.archived.isEmpty else { return [] }
    let expansion = state.expansion
    var rows = [SidebarRow(.section(.archived, isExpanded: expansion.archived))]
    let shown =
      expansion.archived
      ? Array(state.archived.prefix(state.archivedVisibleCount))
      : SidebarCollapse.shown(state.archived, isExpanded: false, keeping: state.selectedWorkspaceID)
    for item in shown {
      rows.append(SidebarRow(.workspace(item, .archived)))
    }
    if expansion.archived && state.archived.count > state.archivedVisibleCount {
      rows.append(SidebarRow(.showMoreArchived))
    }
    return rows
  }

  public static func siblings(of id: UUID, in rows: [SidebarRow]) -> [UUID] {
    guard let row = rows.first(where: { $0.id == .workspace(id) }), case let .workspace(_, placement) = row.kind
    else { return [] }
    return rows.compactMap { candidate in
      guard case let .workspace(item, candidatePlacement) = candidate.kind, candidatePlacement == placement,
        candidate.parentID == row.parentID
      else { return nil }
      return item.id
    }
  }

  public static func subtree(of id: UUID, in rows: [SidebarRow]) -> [UUID] {
    guard let index = rows.firstIndex(where: { $0.id == .workspace(id) }) else { return [] }
    let depth = rows[index].depth
    let descendants = rows[(index + 1)...].prefix { $0.depth > depth && $0.parentID != nil }
    return [id]
      + descendants.compactMap { row in
        guard case let .workspace(item, _) = row.kind else { return nil }
        return item.id
      }
  }

  public static func activeWorkspaceSections(_ rows: [SidebarRow]) -> [[WorkspaceSidebarItem]] {
    var sections: [[WorkspaceSidebarItem]] = []
    var current: SidebarRow.Placement?
    for row in rows {
      guard case let .workspace(item, placement) = row.kind, placement != .archived else {
        current = nil
        continue
      }
      if placement == current {
        sections[sections.count - 1].append(item)
      } else {
        sections.append([item])
        current = placement
      }
    }
    return sections
  }
}
