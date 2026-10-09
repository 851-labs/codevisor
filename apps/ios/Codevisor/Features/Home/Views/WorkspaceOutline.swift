import CodevisorCore
import SwiftUI

/// Workspaces as an outline: each one, then the workspaces nested under it
/// while it is expanded, indented a level. The rows are one flat list, so
/// the system's long-press drag reorders them at any depth: a workspace
/// keeps its level and lands among its siblings nearest the drop.
struct WorkspaceOutline: View {
  @Environment(AppEnvironment.self) private var environment

  let rows: [AgentSidebarRow]
  /// The workspace these are nested under, if any.
  let owner: AgentSidebarRow?
  @Binding var expanded: Set<UUID>
  var isSelectable = false

  struct Entry: Identifiable {
    let row: AgentSidebarRow
    let owner: AgentSidebarRow?
    let depth: Int

    var id: UUID { row.id }
  }

  var body: some View {
    let entries = Self.entries(rows, owner: owner, depth: 0, expanded: expanded)
    ForEach(entries) { entry in
      WorkspaceOutlineRow(
        row: entry.row, owner: entry.owner, expanded: $expanded, isSelectable: isSelectable, depth: entry.depth)
    }
    .onMove { source, destination in move(entries, from: source, to: destination) }
  }

  static func entries(
    _ rows: [AgentSidebarRow], owner: AgentSidebarRow?, depth: Int, expanded: Set<UUID>
  ) -> [Entry] {
    rows.flatMap { row in
      [Entry(row: row, owner: owner, depth: depth)]
        + (expanded.contains(row.id)
          ? entries(row.children, owner: row, depth: depth + 1, expanded: expanded) : [])
    }
  }

  /// The moved workspace goes after every sibling listed above the drop.
  private func move(_ entries: [Entry], from source: IndexSet, to destination: Int) {
    guard let from = source.first, entries.indices.contains(from) else { return }
    let moved = entries[from]
    var rest = entries
    rest.remove(at: from)
    let insertion = destination > from ? destination - 1 : destination
    let isSibling = { (entry: Entry) in entry.owner?.id == moved.owner?.id }
    let siblings = rest.filter(isSibling).map(\.row.id)
    let index = rest.prefix(insertion).filter(isSibling).count
    let navigation = environment.navigationStore
    if moved.owner == nil {
      navigation.moveAgent(moved.row.id, to: index, among: siblings)
    } else {
      navigation.moveNestedAgent(moved.row.id, to: index, among: siblings)
    }
  }
}
