import CodevisorCore
import SwiftUI

struct SidebarWorkspaceSection: View {
  let sidebar: SidebarView
  let item: WorkspaceSidebarItem
  let selection: SidebarSelection?
  let grouping: SidebarGrouping
  let rowDetails: [SidebarRowDetail]
  let draggingID: UUID?

  var body: some View {
    if let listItem = sidebar.listItem(for: item) {
      sidebar.workspaceRow(listItem)
    }
  }
}
