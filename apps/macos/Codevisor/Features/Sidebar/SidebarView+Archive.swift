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
              .transition(Motion.unfold(reduceMotion: reduceMotion))
          }
        }
        if items.count > archivedVisibleCount {
          Button("Show \(min(archivedPageSize, items.count - archivedVisibleCount)) More") {
            withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
              archivedVisibleCount += archivedPageSize
            }
          }
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
        }
      }
    }
  }

  private func archivedRow(_ workspace: Workspace, item: WorkspaceSidebarItem) -> some View {
    let listItem = SidebarWorkspaceListItem(workspace: workspace, routingSession: routingSession(for: item))
    return SidebarArchivedWorkspaceRow(
      name: workspace.name,
      subtitle: archivedSubtitle(for: workspace),
      icon: icon(for: listItem),
      store: store,
      isReordering: isReordering,
      onRequestRestore: { restoringWorkspace = workspace },
      onRestore: { environment.unarchiveWorkspace(workspace) }
    )
  }

  /// Archived rows sit outside every group, so they name their project and
  /// machine like a flat row.
  private func archivedSubtitle(for workspace: Workspace) -> String? {
    let projectName = list.projects.first {
      $0.serverId == workspace.serverId && $0.id == workspace.projectId
    }?.name
    var parts: [String] = []
    for candidate in [projectName, workspace.worktreeName, machineName(forServer: workspace.serverId)] {
      guard let candidate, !candidate.isEmpty, candidate != workspace.name, !parts.contains(candidate) else {
        continue
      }
      parts.append(candidate)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
