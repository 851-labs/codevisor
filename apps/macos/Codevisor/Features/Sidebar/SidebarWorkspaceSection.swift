import CodevisorCore
import SwiftUI

/// One workspace in the sidebar.
///
/// The section resolves its own workspace entry and routing chat, so a tab
/// click or remote edit in one workspace re-renders only that workspace's
/// row; the list above it only follows which workspaces are listed.
struct SidebarWorkspaceSection: View {
  /// The owning sidebar, whose row builder and actions this section reuses.
  let sidebar: SidebarView
  let item: WorkspaceSidebarItem
  /// Sidebar state every row depends on. Passed explicitly so a change
  /// re-evaluates the section rather than relying on the copied sidebar.
  let selection: SidebarSelection?
  /// Whether the row names its machine depends on the grouping.
  let grouping: SidebarGrouping
  /// The dragged workspace, whose row dims in place.
  let draggingID: UUID?

  var body: some View {
    if let listItem = sidebar.listItem(for: item) {
      sidebar.workspaceRow(listItem)
    }
  }
}
