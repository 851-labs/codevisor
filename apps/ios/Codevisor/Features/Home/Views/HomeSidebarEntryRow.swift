import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarEntryRow: View {
  static let indent: CGFloat = 20

  let entry: HomeSidebarListEntry
  let actions: HomeSidebarActionHandler
  let isSelectable: Bool

  var body: some View {
    row
      .padding(.leading, Self.indent * CGFloat(entry.depth))
      .tag(entry.id)
  }

  @ViewBuilder
  private var row: some View {
    switch entry.row {
    case let .workspace(workspace):
      HomeSidebarWorkspaceRowView(workspace: workspace, actions: actions, isSelectionRow: isSelectable)
        .equatable()
    case let .tab(tab, owner):
      HomeSidebarTabRowView(row: tab, workspace: owner.workspace, actions: actions, isSelectionRow: isSelectable)
        .equatable()
    }
  }
}
