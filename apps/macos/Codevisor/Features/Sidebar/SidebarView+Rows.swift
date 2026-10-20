import CodevisorCore
import CodevisorUI

extension SidebarView {
  var sidebarRows: [SidebarRow] {
    SidebarRows.derive(sidebarRowsState())
  }

  func sidebarRowsState(hiding hidden: Set<UUID> = []) -> SidebarRows.State {
    SidebarRows.State(
      bots: botsEnabled ? botEntries.map(SidebarRows.Bot.init) : nil, canCreateBots: canCreateBots,
      groups: hidden.isEmpty ? workspaceGroups : workspaceGroups(listedSidebarItems.filter { !hidden.contains($0.id) }),
      archived: archivedSidebarItems, archivedVisibleCount: archivedVisibleCount,
      expansion: SidebarRows.Expansion(
        bots: botsExpanded, pinned: pinnedExpanded, list: listExpanded, archived: archivedExpanded,
        collapsedGroupIDs: Set(collapsedGroupIDs)),
      selectedWorkspaceID: selectedWorkspaceID, selectedBotID: selectedBotID)
  }
}
