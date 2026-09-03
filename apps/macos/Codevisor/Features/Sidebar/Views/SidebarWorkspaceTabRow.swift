import CodevisorCore
import SwiftUI

/// A workspace tab as a sidebar row (Nous mode): the tab's kind glyph — a
/// chat tab borrows the chat row's live status icon — its title, and a
/// hover close button.
struct SidebarWorkspaceTabRow: View {
  let title: String
  let kind: PaneKind
  let isAgentOwned: Bool
  /// The chat a chat tab shows, when it is still known to the session
  /// list; drives the activity/unread leading icon.
  let chatSession: ChatSession?
  let store: SessionStore?
  let isSelected: Bool
  let isReordering: Bool
  let titleFont: Font
  let hierarchyIndent: CGFloat
  let onActivate: () -> Void
  let onClose: () -> Void
  /// Nil for pane rows, which have no title of their own to pin.
  var onRename: (() -> Void)? = nil
  var closeTitle = "Close Tab"

  var body: some View {
    HoverableRow(
      isSelected: isSelected,
      isHoverEnabled: !isReordering,
      isHoverForced: false
    ) { isHovered in
      HStack(spacing: 7) {
        leadingIcon
        Text(title)
          .font(titleFont)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        if isHovered {
          Button(action: onClose) {
            Image(systemName: "xmark")
              .font(.caption2.weight(.semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help(closeTitle)
          .accessibilityLabel("Close \(title)")
          .frame(width: 24, height: 14, alignment: .trailing)
        }
      }
      .padding(.horizontal, 8)
      .padding(.leading, hierarchyIndent)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .foregroundStyle(isSelected ? Color.primary : .secondary)
      // Activate on pointer-down, like chat rows. A row gesture (not an
      // overlay) keeps the close button and context menu hit-testable.
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in onActivate() }
      )
    }
    .contextMenu {
      if let onRename {
        Button {
          onRename()
        } label: {
          Label("Rename Tab", systemImage: "pencil")
            .labelStyle(.titleAndIcon)
        }
      }
      Button {
        onClose()
      } label: {
        Label(closeTitle, systemImage: "xmark")
          .labelStyle(.titleAndIcon)
      }
    }
  }

  @ViewBuilder
  private var leadingIcon: some View {
    if let chatSession {
      ChatSessionLeadingIcon(session: chatSession, store: store, activityColor: .secondary)
        .foregroundStyle(.secondary)
    } else {
      Image(systemName: PaneTab.iconName(for: kind, isAgentOwned: isAgentOwned))
        .frame(width: 18)
        .foregroundStyle(.secondary)
    }
  }
}
