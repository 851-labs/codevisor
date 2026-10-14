import CodevisorCore
import CodevisorUI
import SwiftUI

let archivedPageSize = 10

extension SidebarView {
  var archivedSidebarItems: [WorkspaceSidebarItem] {
    environment.navigationStore.workspaceEntries.archived.filter {
      environment.machines.machine(for: $0.serverId) != nil
    }
  }

  var listedArchivedWorkspaces: [Workspace] {
    guard archivedExpanded else { return [] }
    return archivedSidebarItems.prefix(archivedVisibleCount).compactMap {
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
          archivedVisibleCount = archivedPageSize
        }
      }
      if archivedExpanded {
        ForEach(items.prefix(archivedVisibleCount)) { item in
          if let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace {
            archivedRow(workspace, item: item)
              .id(workspace.id)
              .transition(Motion.unfold(reduceMotion: reduceMotion))
          }
        }
        if items.count > archivedVisibleCount {
          SidebarActionRow(
            title: "Show More", systemImage: "ellipsis", isSelected: false, isHoverEnabled: !isReordering,
            titleStyle: .secondary
          ) {
            withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
              archivedVisibleCount += archivedPageSize
            }
          }
        }
      }
    }
  }

  private func archivedRow(_ workspace: Workspace, item: WorkspaceSidebarItem) -> some View {
    let listItem = SidebarWorkspaceListItem(workspace: workspace, routingSession: routingSession(for: item))
    return SidebarArchivedWorkspaceRow(
      name: workspace.name,
      subtitle: rowSubtitle(for: workspace, isArchived: true),
      icon: icon(for: listItem),
      store: store,
      isSelected: selection == .archivedWorkspace(serverId: workspace.serverId, id: workspace.id),
      isReordering: isReordering,
      onActivate: { selection = .archivedWorkspace(serverId: workspace.serverId, id: workspace.id) },
      onRestore: { environment.unarchiveWorkspace(workspace) }
    )
  }
}
