import CodevisorCore
import CodevisorUI
import SwiftUI

struct ClassicSidebarWorkspaceSection: View {
  let sidebar: ClassicSidebarView
  let item: WorkspaceSidebarItem
  let selection: SidebarSelection?
  let draggingID: UUID?
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
