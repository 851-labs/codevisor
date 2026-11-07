import CodevisorCore
import Foundation

struct HomeSidebarListEntry: Identifiable {
  enum Row {
    case workspace(HomeSidebarWorkspace)
    case tab(HomeSidebarTabRow, owner: HomeSidebarWorkspace)
  }

  enum Move: Equatable {
    case workspace(UUID, to: Int, among: [UUID])
    case tab(UUID, before: UUID?, in: HomeSidebarWorkspaceRef)
  }

  let row: Row
  let depth: Int
  let parentID: UUID?

  var id: UUID {
    switch row {
    case let .workspace(workspace): workspace.id
    case let .tab(tab, _): tab.id
    }
  }

  static func flatten(_ workspaces: [HomeSidebarWorkspace], depth: Int = 0, parentID: UUID? = nil) -> [Self] {
    workspaces.flatMap { workspace in
      [Self(row: .workspace(workspace), depth: depth, parentID: parentID)]
        + tabs(of: workspace, depth: depth + 1)
        + flatten(workspace.children, depth: depth + 1, parentID: workspace.id)
    }
  }

  static func move(_ index: Int, to destination: Int, in entries: [Self]) -> Move? {
    let moved = entries[index]
    let siblings = entries.indices.filter { entries[$0].isSibling(of: moved) }
    switch moved.row {
    case let .workspace(workspace):
      let target = siblings.filter { $0 < destination && $0 != index }.count
      return .workspace(workspace.id, to: target, among: siblings.map { entries[$0].id })
    case let .tab(tab, owner):
      guard let tabId = tab.tabId else { return nil }
      let rowTabIds = siblings.map { entries[$0].tabRowId }
      let droppedAt = siblings.filter { $0 < destination }.count
      let successor = SharedTabOrder.successor(of: tabId, droppedAt: droppedAt, rowTabIds: rowTabIds)
      return .tab(tabId, before: successor, in: owner.workspace)
    }
  }

  private static func tabs(of workspace: HomeSidebarWorkspace, depth: Int) -> [Self] {
    workspace.nestedRows.map { Self(row: .tab($0, owner: workspace), depth: depth, parentID: workspace.id) }
  }

  private var isTab: Bool {
    if case .tab = row { return true }
    return false
  }

  private var tabRowId: UUID {
    guard case let .tab(tab, _) = row else { return id }
    return tab.tabId ?? tab.id
  }

  private func isSibling(of other: Self) -> Bool {
    parentID == other.parentID && isTab == other.isTab
  }
}
