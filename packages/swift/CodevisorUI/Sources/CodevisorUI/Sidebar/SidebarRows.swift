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

  public let kind: Kind
  public let depth: Int

  public init(_ kind: Kind, depth: Int = 0) {
    self.kind = kind
    self.depth = depth
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
    public var archived: [WorkspaceSidebarItem]
    public var archivedVisibleCount: Int
    public var expansion: Expansion
    public var selectedWorkspaceID: UUID?

    public init(
      groups: [SidebarWorkspaceGroup], archived: [WorkspaceSidebarItem] = [],
      archivedVisibleCount: Int = sidebarArchivedPageSize, expansion: Expansion = Expansion(),
      selectedWorkspaceID: UUID? = nil
    ) {
      self.groups = groups
      self.archived = archived
      self.archivedVisibleCount = archivedVisibleCount
      self.expansion = expansion
      self.selectedWorkspaceID = selectedWorkspaceID
    }
  }

  public static func derive(_ state: State) -> [SidebarRow] {
    var rows: [SidebarRow] = []
    let expansion = state.expansion

    func visible(_ items: [WorkspaceSidebarItem], showing: Bool) -> [WorkspaceSidebarItem] {
      showing ? items : items.filter { $0.id == state.selectedWorkspaceID }
    }

    if let pinned = state.groups.first(where: { $0.id == SidebarWorkspaceGroup.pinnedID }) {
      rows.append(SidebarRow(.section(.pinned, isExpanded: expansion.pinned)))
      for item in visible(pinned.items, showing: expansion.pinned) {
        rows.append(SidebarRow(.workspace(item, .pinned)))
      }
    }

    rows.append(SidebarRow(.section(.list, isExpanded: expansion.list)))
    for group in state.groups where group.id != SidebarWorkspaceGroup.pinnedID {
      let isExpanded = group.heading == nil || !expansion.collapsedGroupIDs.contains(group.id)
      let showsHeading = group.heading != nil && expansion.list
      if let heading = group.heading, showsHeading {
        rows.append(SidebarRow(.group(id: group.id, heading: heading, isExpanded: isExpanded)))
      }
      for item in visible(group.items, showing: expansion.list && isExpanded) {
        rows.append(SidebarRow(.workspace(item, .group(group.id)), depth: showsHeading ? 1 : 0))
      }
    }

    if !state.archived.isEmpty {
      rows.append(SidebarRow(.section(.archived, isExpanded: expansion.archived)))
      let shown =
        expansion.archived
        ? Array(state.archived.prefix(state.archivedVisibleCount))
        : visible(state.archived, showing: false)
      for item in shown {
        rows.append(SidebarRow(.workspace(item, .archived)))
      }
      if expansion.archived && state.archived.count > state.archivedVisibleCount {
        rows.append(SidebarRow(.showMoreArchived))
      }
    }

    return rows
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
