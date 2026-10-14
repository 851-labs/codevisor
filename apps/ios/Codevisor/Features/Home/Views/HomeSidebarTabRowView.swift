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

  private var onRename: (() -> Void)? {
    guard row.renamableTabId != nil else { return nil }
    return { [actions, row, workspace] in actions.actions.rename(row, workspace) }
  }

  private var onOpenInNewWindow: (() -> Void)? {
    guard let open = actions.actions.openInNewWindow else { return nil }
    return { [row, workspace] in open(row, workspace) }
  }

  var body: some View {
    Group {
      if isSelectionRow {
        label
      } else {
        Button(action: onOpen) { label }
          .buttonStyle(.plain)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive, action: onClose) {
        Image(systemName: "xmark")
      }
      .accessibilityLabel("Close")
      if let onRename {
        Button(action: onRename) {
          Image(systemName: "pencil")
        }
        .tint(.indigo)
        .accessibilityLabel("Rename")
      }
    }
    .contextMenu {
      if let onOpenInNewWindow {
        Button(action: onOpenInNewWindow) {
          Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }
        Divider()
      }
      if let onRename {
        Button(action: onRename) {
          Label("Rename Tab", systemImage: "pencil")
        }
      }
      Button(role: .destructive, action: onClose) {
        Label("Close Tab", systemImage: "xmark")
      }
    }
    .accessibilityLabel(accessibilityLabel)
  }

  private var label: some View {
    HStack(spacing: 12) {
      HomeSidebarTabIcon(row: row, serverId: workspace.serverId, size: 17)
        .frame(width: 22, height: 22)
      HomeSidebarRowTitle(title: row.title)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
      Spacer(minLength: 0)
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

private struct HomeSidebarRowTitle: View {
  let title: String
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    Text(title)
      .font(.body)
      .foregroundStyle(backgroundProminence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
  }
}
