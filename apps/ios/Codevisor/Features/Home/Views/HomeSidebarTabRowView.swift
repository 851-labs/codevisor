import CodevisorCore
import CodevisorUI
import SwiftUI

/// A tab as a sidebar row: the kind glyph — a chat's live status replaces
/// its harness icon — and the title. Close and rename live in swipe actions
/// and the long-press menu instead of the macOS hover button.
///
/// In the split layout's selection list the row is plain content: the list
/// owns tapping, the highlight, the selected trait, dismissing an overlay
/// sidebar, and keeping a swipe from selecting. On the phone the row is a
/// button that pushes the tab.
///
/// Equatable on its inputs -- the row, its workspace, and the (stable)
/// action handler -- so a sidebar re-render skips every row that didn't
/// change.
struct HomeSidebarTabRowView: View, Equatable {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let row: HomeSidebarTabRow
  let workspace: HomeSidebarWorkspaceRef
  let actions: HomeSidebarActionHandler
  /// The row lives in a `List(selection:)`, which opens it instead.
  var isSelectionRow = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row && lhs.workspace == rhs.workspace && lhs.actions === rhs.actions
      && lhs.isSelectionRow == rhs.isSelectionRow
  }

  private func onOpen() { actions.actions.open(row, workspace) }
  private func onClose() { actions.actions.close(row, workspace) }

  /// Nil for pane rows, which have no title of their own to pin.
  private var onRename: (() -> Void)? {
    guard row.renamableTabId != nil else { return nil }
    return { [actions, row, workspace] in actions.actions.rename(row, workspace) }
  }

  /// iPad only: shows the tab in a window of its own.
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
      // Glyphs only; the labels stay for VoiceOver.
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
    // Plain buttons hit-test only their drawn pixels; the whole row
    // opens the tab.
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

/// The row's title. The app's theme root pins a global foreground style,
/// which stops the list from switching a selected row's text to white on
/// its accent fill; this follows the list's selection prominence instead,
/// as the row's icon does.
private struct HomeSidebarRowTitle: View {
  let title: String
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    Text(title)
      .font(.body)
      .foregroundStyle(backgroundProminence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
  }
}
