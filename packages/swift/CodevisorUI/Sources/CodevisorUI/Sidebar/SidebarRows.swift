import CodevisorCore
import Foundation

public enum SidebarSection: Hashable, Sendable {
  case pinned
  case custom(UUID)
  case list
  case archived
}

public enum SidebarRowID: Hashable, Sendable {
  case section(SidebarSection)
  case group(String)
  case workspace(UUID)
  case tab(UUID)
  case showMoreArchived
}

public struct SidebarRow: Identifiable, Equatable {
  public enum Placement: Hashable, Sendable {
    case pinned
    case custom(UUID)
    case group(String)
    case archived
  }

  public enum Kind: Equatable {
    case section(SidebarSection, isExpanded: Bool)
    case group(id: String, heading: SidebarWorkspaceGroup.Heading, isExpanded: Bool)
    case workspace(WorkspaceSidebarItem, Placement)
    case tab(UUID, workspaceID: UUID, Placement)
    case showMoreArchived
  }

  public let kind: Kind
  public let depth: Int
  public let parentID: UUID?

  public init(_ kind: Kind, depth: Int = 0, parentID: UUID? = nil) {
    self.kind = kind
    self.depth = depth
    self.parentID = parentID
  }

  public var section: SidebarSection {
    switch kind {
    case let .section(section, _): section
    case .group: .list
    case .showMoreArchived: .archived
    case let .workspace(_, placement), let .tab(_, _, placement): placement.section
    }
  }

  public var id: SidebarRowID {
    switch kind {
    case let .section(section, _): .section(section)
    case let .group(id, _, _): .group(id)
    case let .workspace(item, _): .workspace(item.id)
    case let .tab(id, _, _): .tab(id)
    case .showMoreArchived: .showMoreArchived
    }
  }
}

extension SidebarRow.Placement {
  fileprivate var section: SidebarSection {
    switch self {
    case .pinned: .pinned
    case let .custom(id): .custom(id)
    case .group: .list
    case .archived: .archived
    }
  }
}

public enum SidebarRows {
  public struct Expansion: Equatable, Sendable {
    public var pinned: Bool
    public var list: Bool
    public var archived: Bool
    public var collapsedGroupIDs: Set<String>

    public init(
      pinned: Bool = true, list: Bool = true, archived: Bool = false, collapsedGroupIDs: Set<String> = []
    ) {
      self.pinned = pinned
      self.list = list
      self.archived = archived
      self.collapsedGroupIDs = collapsedGroupIDs
    }
  }

  public struct State: Equatable {
    public var groups: [SidebarWorkspaceGroup]
    public var children: [UUID: [WorkspaceSidebarItem]]
    public var tabs: [UUID: [UUID]]
    public var archived: [WorkspaceSidebarItem]
    public var archivedVisibleCount: Int
    public var expansion: Expansion
    public var selectedWorkspaceID: UUID?
    public var selectedTabID: UUID?

    public init(
      groups: [SidebarWorkspaceGroup], children: [UUID: [WorkspaceSidebarItem]] = [:], tabs: [UUID: [UUID]] = [:],
      archived: [WorkspaceSidebarItem] = [], archivedVisibleCount: Int = sidebarArchivedPageSize,
      expansion: Expansion = Expansion(), selectedWorkspaceID: UUID? = nil, selectedTabID: UUID? = nil
    ) {
      self.groups = groups
      self.children = children
      self.tabs = tabs
      self.archived = archived
      self.archivedVisibleCount = archivedVisibleCount
      self.expansion = expansion
      self.selectedWorkspaceID = selectedWorkspaceID
      self.selectedTabID = selectedTabID
    }
  }

  public static func derive(_ state: State) -> [SidebarRow] {
    guard hasActiveWorkspaces(state) else { return archivedRows(state) }

    return activeRows(state) + archivedRows(state)
  }

  private static func activeRows(_ state: State) -> [SidebarRow] {
    var rows: [SidebarRow] = []
    let expansion = state.expansion

    func appendWorkspace(
      _ item: WorkspaceSidebarItem, _ placement: SidebarRow.Placement, depth: Int, parentID: UUID? = nil,
      showing: Bool
    ) {
      let tabs = state.tabs[item.id] ?? []
      let isSelected = item.id == state.selectedWorkspaceID
      if showing || isSelected {
        rows.append(SidebarRow(.workspace(item, placement), depth: depth, parentID: parentID))
        let selectedTab = isSelected ? state.selectedTabID : nil
        let shownTabs = showing ? tabs : keptTab(of: tabs, selected: selectedTab)
        rows += tabRows(shownTabs, of: item.id, placement, depth: depth + 1)
      }
      for child in state.children[item.id] ?? [] {
        appendWorkspace(child, placement, depth: showing ? depth + 1 : depth, parentID: item.id, showing: showing)
      }
    }

    if let pinned = state.groups.first(where: { $0.id == SidebarWorkspaceGroup.pinnedID }) {
      rows.append(SidebarRow(.section(.pinned, isExpanded: expansion.pinned)))
      for item in pinned.items {
        appendWorkspace(item, .pinned, depth: 0, showing: expansion.pinned)
      }
    }

    for group in state.groups {
      guard let section = group.customSection else { continue }
      let isExpanded = !expansion.collapsedGroupIDs.contains(group.id)
      rows.append(SidebarRow(.section(.custom(section.id), isExpanded: isExpanded)))
      for item in group.items {
        appendWorkspace(item, .custom(section.id), depth: 0, showing: isExpanded)
      }
    }

    rows.append(SidebarRow(.section(.list, isExpanded: expansion.list)))
    for group in state.groups where group.id != SidebarWorkspaceGroup.pinnedID && group.customSection == nil {
      let isExpanded = group.heading == nil || !expansion.collapsedGroupIDs.contains(group.id)
      let showsHeading = group.heading != nil && expansion.list
      if let heading = group.heading, showsHeading {
        rows.append(SidebarRow(.group(id: group.id, heading: heading, isExpanded: isExpanded)))
      }
      for item in group.items {
        appendWorkspace(item, .group(group.id), depth: showsHeading ? 1 : 0, showing: expansion.list && isExpanded)
      }
    }

    return rows
  }

  private static func hasActiveWorkspaces(_ state: State) -> Bool {
    state.groups.contains { !$0.items.isEmpty }
  }

  private static func archivedRows(_ state: State) -> [SidebarRow] {
    let archived = state.archived.filter { !QuietChildren.isQuiet($0) }
    guard !archived.isEmpty else { return [] }
    let expansion = state.expansion
    var rows = [SidebarRow(.section(.archived, isExpanded: expansion.archived))]
    let shown =
      expansion.archived
      ? Array(archived.prefix(state.archivedVisibleCount))
      : SidebarCollapse.shown(archived, isExpanded: false, keeping: state.selectedWorkspaceID)
    for item in shown {
      rows.append(SidebarRow(.workspace(item, .archived)))
      rows += tabRows(state.tabs[item.id] ?? [], of: item.id, .archived, depth: 1)
    }
    if expansion.archived && archived.count > state.archivedVisibleCount {
      rows.append(SidebarRow(.showMoreArchived))
    }
    return rows
  }

  private static func keptTab(of tabs: [UUID], selected: UUID?) -> [UUID] {
    guard let selected, tabs.contains(selected) else { return [] }
    return [selected]
  }

  private static func tabRows(
    _ tabs: [UUID], of workspaceID: UUID, _ placement: SidebarRow.Placement, depth: Int
  ) -> [SidebarRow] {
    tabs.map { SidebarRow(.tab($0, workspaceID: workspaceID, placement), depth: depth, parentID: workspaceID) }
  }

  public static func tabs(of workspaceID: UUID, in rows: [SidebarRow]) -> [UUID] {
    rows.compactMap { row in
      guard case let .tab(id, owner, _) = row.kind, owner == workspaceID else { return nil }
      return id
    }
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
      if case .tab = row.kind { continue }
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
