import CodevisorCore
import SwiftUI

/// A folder, or a project when grouped by project: a row of the list that
/// discloses the workspaces in it.
struct HomeSidebarGroup {
  let id: String
  let title: String
  let rows: [AgentSidebarRow]
  var folder: ServerNavigationFolder?
  var projectId: UUID?
}

/// One row of the root list, in display order: a folder (or project) or a
/// workspace, with how deep it sits and the group it's listed in. The rows
/// are one flat list, so the system's long-press drag moves any of them
/// anywhere: a workspace into, out of or between folders, a folder among
/// the others.
struct HomeSidebarEntry: Identifiable {
  enum Kind {
    case group(HomeSidebarGroup)
    /// A workspace, and the workspace it's nested under, if any.
    case agent(AgentSidebarRow, owner: AgentSidebarRow?)
  }

  let kind: Kind
  let depth: Int
  /// The folder (or project) it's listed in; nil at the top level.
  let groupId: String?

  var id: String {
    switch kind {
    case let .group(group): "group:\(group.id)"
    case let .agent(row, _): row.id.uuidString
    }
  }

  var group: HomeSidebarGroup? {
    if case let .group(group) = kind { group } else { nil }
  }

  var agent: AgentSidebarRow? {
    if case let .agent(row, _) = kind { row } else { nil }
  }

  var owner: AgentSidebarRow? {
    if case let .agent(_, owner) = kind { owner } else { nil }
  }

  /// A row its folder (or the top level) sorts by: a group, or a workspace
  /// not nested under another.
  var isPlaced: Bool { owner == nil }

  /// Where it sorts among its neighbors: a folder's or a workspace's place.
  var position: String? {
    switch kind {
    case let .group(group): group.folder?.position
    case let .agent(row, owner): owner == nil ? row.position : nil
    }
  }

  /// The list's rows: each node, then what it discloses while expanded.
  static func entries(
    _ nodes: [AgentSidebarNode], expandedWorkspaces: Set<UUID>, isExpanded: (HomeSidebarGroup) -> Bool
  ) -> [HomeSidebarEntry] {
    func agent(_ row: AgentSidebarRow, owner: AgentSidebarRow?, depth: Int, groupId: String?) -> [HomeSidebarEntry] {
      [HomeSidebarEntry(kind: .agent(row, owner: owner), depth: depth, groupId: groupId)]
        + (expandedWorkspaces.contains(row.id)
          ? row.children.flatMap { agent($0, owner: row, depth: depth + 1, groupId: groupId) } : [])
    }
    func group(_ group: HomeSidebarGroup) -> [HomeSidebarEntry] {
      [HomeSidebarEntry(kind: .group(group), depth: 0, groupId: nil)]
        + (isExpanded(group) ? group.rows.flatMap { agent($0, owner: nil, depth: 1, groupId: group.id) } : [])
    }
    return nodes.flatMap { node in
      switch node {
      case let .agent(row):
        agent(row, owner: nil, depth: 0, groupId: nil)
      case let .folder(folder, rows):
        group(HomeSidebarGroup(id: folder.id, title: folder.name, rows: rows, folder: folder))
      case let .project(project, rows):
        group(
          HomeSidebarGroup(
            id: "\(project.serverId):\(project.id)", title: project.name, rows: rows, projectId: project.id))
      }
    }
  }
}

/// Where a dropped row lands, from the rows around the drop.
struct HomeSidebarDrop {
  /// The other rows, in order, without the moved one.
  let rest: [HomeSidebarEntry]
  /// Where in `rest` it was dropped.
  let index: Int
  /// The groups the list shows open.
  let openGroups: Set<String>

  init(_ entries: [HomeSidebarEntry], from: Int, to destination: Int, openGroups: Set<String>) {
    var rest = entries
    rest.remove(at: from)
    self.rest = rest
    index = destination > from ? destination - 1 : destination
    self.openGroups = openGroups
  }

  private var previous: HomeSidebarEntry? { index > 0 ? rest[index - 1] : nil }
  private var next: HomeSidebarEntry? { index < rest.count ? rest[index] : nil }

  /// The folder (or project) a workspace dropped here joins; nil for the
  /// top level. Above a group's workspace it joins that group; right under
  /// an open group's row, that group (an empty one: a full one's workspace
  /// would be next); after its own group's last workspace, it stays in it.
  /// Anywhere else is the top level.
  func groupId(movingFrom current: String?) -> String? {
    if let next, next.agent != nil, let group = next.groupId { return group }
    if let group = previous?.group, openGroups.contains(group.id) { return group.id }
    if let previous, previous.agent != nil, let group = previous.groupId, group == current { return group }
    return nil
  }

  /// The positions of the placed rows of `groupId` (the top level when nil)
  /// just before and after the drop.
  func neighbors(in groupId: String?) -> (lower: String?, upper: String?) {
    let level = { (entry: HomeSidebarEntry) in
      entry.isPlaced && (groupId == nil ? entry.depth == 0 : entry.groupId == groupId && entry.agent != nil)
    }
    let lower = rest.prefix(index).last(where: level)?.position
    let upper = rest.dropFirst(index).first(where: level)?.position
    return (lower, upper)
  }

  /// How many rows matching `isSibling` sit above the drop.
  func count(where isSibling: (HomeSidebarEntry) -> Bool) -> Int {
    rest.prefix(index).filter(isSibling).count
  }

  /// Whether the drop sits right beside a row matching `isSibling`.
  func touches(where isSibling: (HomeSidebarEntry) -> Bool) -> Bool {
    previous.map(isSibling) == true || next.map(isSibling) == true
  }
}

/// A folder (or project) row: its name, how many workspaces it holds, and
/// a chevron that discloses them. Tapping it opens or closes it.
struct HomeFolderRow: View {
  let group: HomeSidebarGroup
  let isExpanded: Bool
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 10) {
        Image(systemName: "folder")
          .foregroundStyle(.secondary)
          .frame(width: 20)
        Text(group.title).lineLimit(1)
        Spacer(minLength: 0)
        HStack(spacing: 0) {
          if !group.rows.isEmpty {
            Text("\(group.rows.count)").foregroundStyle(.secondary).monospacedDigit()
          }
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            // Where a workspace row's disclosure sits.
            .padding(.trailing, 2)
            .frame(width: 23, height: 24, alignment: .trailing)
        }
      }
      .contentShape(Rectangle())
    }
    .foregroundStyle(.primary)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
  }
}
