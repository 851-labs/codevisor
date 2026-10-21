import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  var archivedSidebarItems: [WorkspaceSidebarItem] {
    environment.navigationStore.workspaceEntries.archived.filter {
      environment.machines.machine(for: $0.serverId) != nil
    }
  }

  func toggleArchived() {
    if !archivedExpanded { archivedVisibleCount = sidebarArchivedPageSize }
    archivedExpanded.toggle()
  }

  func archivedRow(_ workspace: Workspace, item: WorkspaceSidebarItem) -> some View {
    let listItem = SidebarWorkspaceListItem(workspace: workspace, routingSession: routingSession(for: item))
    let selected = SidebarSelection.archivedWorkspace(serverId: workspace.serverId, id: workspace.id)
    return row(
      for: workspace,
      icon: icon(for: listItem),
      isSelected: selection == selected,
      onActivate: { selection = selected },
      lifecycle: .archived(onRestore: { environment.unarchiveWorkspace(workspace) })
    )
  }
}
