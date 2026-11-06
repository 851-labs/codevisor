import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarWorkspaceRows: View {
  static let indent: CGFloat = 20

  let workspaces: [HomeSidebarWorkspace]
  var sections: [CustomSection] = []
  let actions: HomeSidebarActionHandler
  let isSelectable: Bool
  var reorders = true

  var body: some View {
    let entries = HomeSidebarListEntry.flatten(workspaces)
    ForEach(entries) { entry in
      row(entry)
        .padding(.leading, Self.indent * CGFloat(entry.depth))
        .tag(entry.id)
    }
    .onMove(perform: reorders ? { move($0, to: $1, in: entries) } : nil)
  }

  @ViewBuilder
  private func row(_ entry: HomeSidebarListEntry) -> some View {
    switch entry.row {
    case let .workspace(workspace):
      HomeSidebarWorkspaceRowView(
        workspace: workspace, actions: actions, isSelectionRow: isSelectable,
        sections: entry.depth == 0 ? sections : []
      )
      .equatable()
    case let .tab(tab, owner):
      HomeSidebarTabRowView(row: tab, workspace: owner.workspace, actions: actions, isSelectionRow: isSelectable)
        .equatable()
    }
  }

  private func move(_ source: IndexSet, to destination: Int, in entries: [HomeSidebarListEntry]) {
    guard let index = source.first, let move = HomeSidebarListEntry.move(index, to: destination, in: entries)
    else { return }

    switch move {
    case let .workspace(id, target, siblings):
      actions.actions.reorder(id, target, siblings)
    case let .tab(tabId, successor, workspace):
      actions.actions.moveTab(tabId, successor, workspace)
    }
  }
}
