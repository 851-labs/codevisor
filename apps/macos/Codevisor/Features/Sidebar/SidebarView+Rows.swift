import CodevisorCore
import CodevisorUI

extension SidebarView {
  var sidebarRows: [SidebarRow] {
    let unrevealed = SidebarRows.derive(sidebarRowsState(revealing: nil))
    guard let revealed = selectionModel.reveal(amongUnrevealed: Set(unrevealed.map(\.id))) else {
      return unrevealed
    }

    return SidebarRows.derive(sidebarRowsState(revealing: revealed))
  }

  func sidebarRowsState(revealing revealed: SidebarRevealedSelection?) -> SidebarRows.State {
    let listing = workspaceListing(revealing: revealed)
    let tree = listing.tree
    return SidebarRows.State(
      groups: listing.groups(of: tree.roots), children: tree.children,
      tabs: nestedTabs(of: listing.listedItems, revealing: revealed),
      archived: archivedSidebarItems, archivedVisibleCount: archivedVisibleCount,
      expansion: SidebarRows.Expansion(
        pinned: pinnedExpanded, list: listExpanded, archived: archivedExpanded,
        collapsedGroupIDs: Set(collapsedGroupIDs)),
      selectedWorkspaceID: revealed?.workspaceID, selectedTabID: revealed?.tabID)
  }
}
