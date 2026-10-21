import CodevisorCore
import CodevisorUI

extension SidebarView {
  var sidebarRows: [SidebarRow] {
    SidebarRows.derive(sidebarRowsState())
  }

  func sidebarRowsState() -> SidebarRows.State {
    SidebarRows.State(
      bots: botsEnabled ? botEntries.map(SidebarRows.Bot.init) : nil, canCreateBots: canCreateBots,
      groups: workspaceGroups,
      archived: archivedSidebarItems, archivedVisibleCount: archivedVisibleCount,
      expansion: SidebarRows.Expansion(
        bots: botsExpanded, pinned: pinnedExpanded, list: listExpanded, archived: archivedExpanded,
        collapsedGroupIDs: Set(collapsedGroupIDs)),
      selectedWorkspaceID: selectedWorkspaceID, selectedBotID: selectedBotID)
  }
}
