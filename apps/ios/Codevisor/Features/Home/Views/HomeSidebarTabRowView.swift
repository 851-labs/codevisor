import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarTabRowView: View, Equatable {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let row: HomeSidebarTabRow
  let workspace: HomeSidebarWorkspaceRef
  let actions: HomeSidebarActionHandler
  var isSelectionRow = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row && lhs.workspace == rhs.workspace && lhs.actions === rhs.actions
      && lhs.isSelectionRow == rhs.isSelectionRow
  }

  private func onOpen() { actions.actions.open(row, workspace) }
  private func onClose() { actions.actions.close(row, workspace) }

  var body: some View {
    Group {
      if isSelectionRow {
        label
      } else {
        Button(action: onOpen) { label }
          .buttonStyle(.plain)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: !row.isMainChat) {
      if !row.isMainChat {
        Button(role: .destructive, action: onClose) {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("Close")
      }
    }
    .accessibilityLabel(accessibilityLabel)
  }

  private var label: some View {
    Label {
      HomeSidebarRowTitle(title: row.title)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    } icon: {
      HomeSidebarTabIcon(row: row, serverId: workspace.serverId)
    }
    .contentShape(Rectangle())
  }

  private var accessibilityLabel: String {
    switch row.status {
    case .error: "\(row.title), error"
    case .actionRequired: "\(row.title), needs attention"
    case .unread: "\(row.title), unread"
    case .inProgress: "\(row.title), working"
    case .idle: row.title
    }
  }
}
