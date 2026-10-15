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

  static let archivedFoldID = "archived"
  static let archivedPageFoldID = "archived.page"

  @ViewBuilder
  var archivedSection: some View {
    let items = archivedSidebarItems
    if !items.isEmpty {
      SidebarSectionHeader(title: "Archived", isExpanded: archivedExpanded) {
        fold(Self.archivedFoldID) {
          if !archivedExpanded { archivedVisibleCount = sidebarArchivedPageSize }
          archivedExpanded.toggle()
        }
      }
      archivedList(items)
    }
  }

  private func archivedList(_ items: [WorkspaceSidebarItem]) -> some View {
    let isFolding = folds.isFolding(Self.archivedFoldID)
    let isPaging = folds.isFolding(Self.archivedPageFoldID)
    let released = withReleasedRows(visibleArchivedItems, from: items)
    let rows = isFolding ? Array(items.prefix(archivedVisibleCount)) : released.items
    let folding = isFolding ? Set(rows.map(\.id)).subtracting([selectedWorkspaceID].compactMap { $0 }) : []
    let pages = archivedPages(rows)
    let hasMore = items.count > archivedVisibleCount
    return SidebarFoldingList(shows: archivedExpanded) { section in
      ForEach(pages.indices, id: \.self) { index in
        let unfolding = isPaging && index == pages.count - 1
        let keepsSelection = pages[index].contains { $0.id == selectedWorkspaceID }
        SidebarFoldingList(
          shows: archivedExpanded || (isFolding && !keepsSelection), appearsFolded: unfolding,
          isReleasing: pages[index].contains { released.releasing.contains($0.id) }
        ) { progress in
          ForEach(pages[index]) { item in
            if let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace {
              archivedRow(workspace, item: item)
                .sidebarFoldingRow(
                  released.releasing.contains(item.id)
                    ? .releasing : unfolding || folding.contains(item.id) ? .folding : .kept,
                  progress: progress, shows: archivedExpanded
                )
                .transition(.identity)
                .id(workspace.id)
            }
          }
        }
        .sidebarFoldingRow(isFolding && !keepsSelection, progress: section, shows: archivedExpanded)
      }
      if (archivedExpanded || isFolding) && (hasMore || isPaging) {
        SidebarFoldingList(shows: archivedExpanded && hasMore, appearsFolded: isFolding) { progress in
          SidebarActionRow(
            title: "Show More", systemImage: "ellipsis", isSelected: false, isHoverEnabled: !isReordering,
            titleStyle: .secondary
          ) {
            fold(Self.archivedPageFoldID) { archivedVisibleCount += sidebarArchivedPageSize }
          }
          .sidebarFoldingRow(isFolding || !hasMore, progress: progress, shows: archivedExpanded && hasMore)
        }
        .sidebarFoldingRow(isFolding, progress: section, shows: archivedExpanded)
      }
    }
  }

  private func archivedPages(_ rows: [WorkspaceSidebarItem]) -> [[WorkspaceSidebarItem]] {
    let pages = stride(from: 0, to: rows.count, by: sidebarArchivedPageSize).map {
      Array(rows[$0..<min($0 + sidebarArchivedPageSize, rows.count)])
    }
    return pages.isEmpty ? [[]] : pages
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
