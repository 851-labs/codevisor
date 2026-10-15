import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  var archivedSidebarItems: [WorkspaceSidebarItem] {
    environment.navigationStore.workspaceEntries.archived.filter {
      environment.machines.machine(for: $0.serverId) != nil
    }
  }

  var visibleArchivedItems: [WorkspaceSidebarItem] {
    let items = archivedSidebarItems
    if archivedExpanded { return Array(items.prefix(archivedVisibleCount)) }
    guard let selectedWorkspaceID else { return [] }
    return items.filter { $0.id == selectedWorkspaceID }
  }

  var listedArchivedWorkspaces: [Workspace] {
    visibleArchivedItems.compactMap {
      environment.navigationStore.workspaceEntries.entry($0.id).workspace
    }
  }

  @ViewBuilder
  var archivedSection: some View {
    let items = archivedSidebarItems
    if !items.isEmpty {
      SidebarSectionHeader(title: "Archived", isExpanded: archivedExpanded) {
        withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
          archivedExpanded.toggle()
          archivedVisibleCount = sidebarArchivedPageSize
        }
      }
      ForEach(visibleArchivedItems) { item in
        if let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace {
          archivedRow(workspace, item: item)
            .id(workspace.id)
            .transition(Motion.unfold(reduceMotion: reduceMotion))
        }
      }
      if archivedExpanded {
        if items.count > archivedVisibleCount {
          SidebarActionRow(
            title: "Show More", systemImage: "ellipsis", isSelected: false, isHoverEnabled: !isReordering,
            titleStyle: .secondary
          ) {
            withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
              archivedVisibleCount += sidebarArchivedPageSize
            }
          }
        }
      }
    }
  }

  private func archivedRow(_ workspace: Workspace, item: WorkspaceSidebarItem) -> some View {
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
