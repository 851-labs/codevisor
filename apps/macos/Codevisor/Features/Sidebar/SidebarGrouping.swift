import CodevisorCore
import Foundation

enum SidebarGrouping: String, CaseIterable, Codable {
  case flat
  case project
  case machine

  static let preferenceKey = "sidebar.grouping"
  static let collapsedPreferenceKey = "sidebar.collapsedGroups"

  var title: String {
    switch self {
    case .flat: "None"
    case .project: "Project"
    case .machine: "Machine"
    }
  }

  var listTitle: String {
    switch self {
    case .flat: "Workspaces"
    case .project: "Projects"
    case .machine: "Machines"
    }
  }
}

struct SidebarWorkspaceGroup: Identifiable, Equatable {
  struct Heading: Equatable {
    let title: String
    let systemImage: String
    var newChatTarget: NewChatTarget? = nil
  }

  static let pinnedID = "pinned"

  let id: String
  let heading: Heading?
  let items: [WorkspaceSidebarItem]

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
