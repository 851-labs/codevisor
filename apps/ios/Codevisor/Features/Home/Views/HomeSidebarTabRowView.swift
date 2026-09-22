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
struct HomeSidebarTabRowView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let row: HomeSidebarTabRow
  let serverId: String
  let onOpen: () -> Void
  let onClose: () -> Void
  /// Nil for pane rows, which have no title of their own to pin.
  let onRename: (() -> Void)?
  /// The row lives in a `List(selection:)`, which opens it instead.
  var isSelectionRow = false

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
      HomeSidebarTabIcon(row: row, serverId: serverId, size: 17)
        .frame(width: 22, height: 22)
      Text(row.title)
        .font(.body)
        .foregroundStyle(.primary)
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
