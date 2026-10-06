import CodevisorCore
import Foundation

/// How the sidebar groups its workspace rows. A per-device preference.
enum SidebarGrouping: String, CaseIterable, Codable {
  case flat
  case project
  case machine

  static let preferenceKey = "sidebar.grouping"

  var title: String {
    switch self {
    case .flat: "None"
    case .project: "Project"
    case .machine: "Machine"
    }
  }
}

/// A run of workspace rows under one heading. A flat sidebar is one
/// untitled group.
struct SidebarWorkspaceGroup: Identifiable, Equatable {
  let id: String
  /// Nil for the flat sidebar's single group, which has no heading.
  let title: String?
  /// Context the title lacks: a project's machine.
  var subtitle: String? = nil
  let items: [WorkspaceSidebarItem]

  /// Splits `items` into groups by `key`. Groups appear in the order of
  /// their first workspace and rows keep their order, so a manual order
  /// carries over into every grouping.
  static func grouping(
    _ items: [WorkspaceSidebarItem],
    by key: (WorkspaceSidebarItem) -> String,
    heading: (WorkspaceSidebarItem) -> (title: String, subtitle: String?)
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
      let heading = heading(first)
      return SidebarWorkspaceGroup(id: id, title: heading.title, subtitle: heading.subtitle, items: items)
    }
  }
}
