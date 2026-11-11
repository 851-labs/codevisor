import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  var archivedSidebarItems: [WorkspaceSidebarItem] {
    let machineIds = environment.machines.allMachineIds
    return environment.navigationStore.workspaceEntries.archived.filter { machineIds.contains($0.serverId) }
  }

  func toggleArchived() {
    if !archivedExpanded { archivedVisibleCount = sidebarArchivedPageSize }
    archivedExpanded.toggle()
  }

  func archivedRow(_ workspace: Workspace, item: WorkspaceSidebarItem, isSelected: Bool) -> some View {
    let listItem = SidebarWorkspaceListItem(workspace: workspace, routingSession: routingSession(for: item))
    return SidebarWorkspaceRow(
      details: rowContent.details(for: listItem, isPinned: isPinned(workspace), headingNamesMachine: false),
      store: store,
      isSelected: isSelected,
      isReordering: isReordering,
      onActivate: { selectTab(workspace.mainTab.id, in: workspace.id) },
      lifecycle: .archived(onRestore: { environment.unarchiveWorkspace(workspace) })
    )
  }

  var showMoreArchivedRow: some View {
    SidebarActionRow(
      title: "Show More", systemImage: "ellipsis", isSelected: false, isHoverEnabled: !isReordering,
      titleStyle: .secondary
    ) {
      archivedVisibleCount += sidebarArchivedPageSize
    }
  }
}
