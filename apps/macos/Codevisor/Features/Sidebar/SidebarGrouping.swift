import CodevisorCore
import Foundation

/// How the sidebar groups its workspace rows. A per-device preference.
enum SidebarGrouping: String, CaseIterable, Codable {
  case flat
  case project
  case machine

  static let preferenceKey = "sidebar.grouping"
  /// The groups the user collapsed, by `SidebarWorkspaceGroup.id`.
  static let collapsedPreferenceKey = "sidebar.collapsedGroups"

  var title: String {
    switch self {
    case .flat: "None"
    case .project: "Project"
    case .machine: "Machine"
    }
  }

  /// The sidebar's heading: what its top-level rows are.
  var listTitle: String {
    switch self {
    case .flat: "Workspaces"
    case .project: "Projects"
    case .machine: "Machines"
    }
  }
}

/// A collapsible run of workspace rows under a project or machine row. A
/// flat sidebar is one untitled group.
struct SidebarWorkspaceGroup: Identifiable, Equatable {
  /// What a group row shows and offers.
  struct Heading: Equatable {
    let title: String
    /// Context the title lacks: a project's machine when there are several.
    var subtitle: String? = nil
    let systemImage: String
    /// Where the row's New Chat starts one. Nil for machines.
    var newChatTarget: NewChatTarget? = nil
  }

  /// The section pinned workspaces move into, above the list's heading.
  static let pinnedID = "pinned"

  /// Namespaced by grouping, so collapsing a project never collapses a
  /// machine that happens to share its key.
  let id: String
  /// Nil for the flat sidebar's single group, which has no row.
  let heading: Heading?
  let items: [WorkspaceSidebarItem]

  /// Splits `items` into groups by `key`. Groups appear in the order of
  /// their first workspace and rows keep their order, so a manual order
  /// carries over into every grouping.
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
