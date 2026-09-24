import CodevisorCore
import CodevisorUI
import SwiftUI

/// One workspace in the sidebar: its header over its tab rows.
///
/// The section resolves its own workspace entry and routing chat, so a tab
/// click or remote edit in one workspace re-renders only that workspace's
/// section; the list above it only follows which workspaces are listed.
struct SidebarWorkspaceSection: View {
  /// The owning sidebar, whose row builders and actions this section reuses.
  let sidebar: SidebarView
  let item: WorkspaceSidebarItem
  /// Sidebar state every row depends on. Passed explicitly so a change
  /// re-evaluates the section rather than relying on the copied sidebar.
  let selection: SidebarSelection?
  let draggingWorkspaceID: UUID?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if let listItem = sidebar.listItem(for: item) {
      sidebar.workspaceSection(listItem)
        .animation(
          Motion.listReflow(reduceMotion: reduceMotion),
          value: sidebar.tabRowIDs(in: listItem.workspace)
        )
    }
  }
}
