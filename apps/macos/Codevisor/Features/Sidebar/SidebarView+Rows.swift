import CodevisorCore
import CodevisorUI

extension SidebarView {
  var sidebarRows: [SidebarRow] {
    SidebarRows.derive(sidebarRowsState())
  }

  func sidebarRowsState() -> SidebarRows.State {
    SidebarRows.State(
      groups: workspaceGroups,
      archived: archivedSidebarItems, archivedVisibleCount: archivedVisibleCount,
      expansion: SidebarRows.Expansion(
        pinned: pinnedExpanded, list: listExpanded, archived: archivedExpanded,
        collapsedGroupIDs: Set(collapsedGroupIDs)),
      selectedWorkspaceID: selectedWorkspaceID)
  }
}
