import CodevisorCore
import CodevisorUI

extension SidebarView {
  var sidebarRows: [SidebarRow] {
    SidebarRows.derive(sidebarRowsState())
  }

  func sidebarRowsState() -> SidebarRows.State {
    let listing = workspaceListing
    let tree = listing.tree
    return SidebarRows.State(
      groups: listing.groups(of: tree.roots), children: tree.children,
      archived: archivedSidebarItems, archivedVisibleCount: archivedVisibleCount,
      expansion: SidebarRows.Expansion(
        pinned: pinnedExpanded, list: listExpanded, archived: archivedExpanded,
        collapsedGroupIDs: Set(collapsedGroupIDs),
        expandedWorkspaceIDs: Set(expandedWorkspaceIDs.compactMap(UUID.init(uuidString:)))),
      selectedWorkspaceID: selectedWorkspaceID)
  }
}
