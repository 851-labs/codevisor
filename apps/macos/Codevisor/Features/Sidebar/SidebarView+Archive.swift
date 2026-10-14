import CodevisorCore
import CodevisorUI
import SwiftUI

/// How many archived workspaces one page reveals.
let archivedPageSize = 10

/// The Archived section: workspaces the user archived, newest first, behind
/// a collapsed heading at the bottom of the list. Restoring brings a
/// workspace back with its tabs and worktree; it then lists normally.
extension SidebarView {
  /// The archived workspaces on machines this Mac knows.
  var archivedSidebarItems: [WorkspaceSidebarItem] {
    environment.navigationStore.workspaceEntries.archived.filter {
      environment.machines.machine(for: $0.serverId) != nil
    }
  }

  /// The archived rows on screen, in order: none while the section is
  /// collapsed, and only the pages already shown. For keyboard stepping --
  /// never read from a view body.
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
        // Paged: a long archive would otherwise lay out hundreds of rows.
        ForEach(items.prefix(archivedVisibleCount)) { item in
          if let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace {
            archivedRow(workspace, item: item)
              // Keyboard stepping scrolls a row it lands on into view.
              .id(workspace.id)
              .transition(Motion.unfold(reduceMotion: reduceMotion))
          }
        }
        if items.count > archivedVisibleCount {
          // A row like New chat's, revealing the next page; its title
          // reads as secondary, an affordance rather than a workspace.
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
