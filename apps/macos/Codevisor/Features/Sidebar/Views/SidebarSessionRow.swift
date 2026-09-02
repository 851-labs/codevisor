import CodevisorCore
import SwiftUI

/// A compact chat row (no project subtitle) used inside project/workspace
/// disclosures and the archived list.
struct SidebarSessionRow: View {
  let session: ChatSession
  let store: SessionStore?
  var isDragPreview = false
  var hierarchyDepth = 0
  var isArchivedEntry = false
  var activatesOnMouseDown = true
  let isSelected: Bool
  let isReordering: Bool
  let titleFont: Font
  let hierarchyIndent: CGFloat
  /// Deferred so the unread state is read when the context menu opens,
  /// exactly as the previous inline builder did.
  /// Fleet context: the owning machine's name, shown only when more than
  /// one machine exists (nil hides it entirely).
  var machineName: String? = nil
  let isUnread: () -> Bool
  let onActivate: () -> Void
  let onRestoreRequest: () -> Void
  let onRename: () -> Void
  let onArchive: () -> Void
  let onMarkRead: () -> Void
  let onMarkUnread: () -> Void

  var body: some View {
    HoverableRow(
      isSelected: isSelected,
      isHoverEnabled: !isReordering,
      isHoverForced: isDragPreview
    ) { isHovered in
      HStack(spacing: 6) {
        HStack(spacing: 6) {
          // Same icon slot as project rows so titles align; the row's
          // dimmer foreground tints the icon along with the text.
          ChatSessionLeadingIcon(
            session: session,
            store: store,
            activityColor: isSelected ? Color.primary : .secondary
          )
          .frame(width: 18)
          Text(session.title)
            .font(titleFont)
            .lineLimit(1)
          if let machineName {
            Text(machineName)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
          Spacer(minLength: 6)
        }

        // An archived chat has nothing left to archive, so the hover
        // affordance is suppressed rather than offering a no-op.
        SidebarSessionStatus(
          session: session,
          store: store,
          isHovered: isHovered && !isArchivedEntry,
          onArchive: onArchive
        )
      }
      .padding(.horizontal, 8)
      .padding(.leading, CGFloat(hierarchyDepth) * hierarchyIndent)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      // A zero-distance drag begins on mouse-down, unlike a tap gesture,
      // which waits for mouse-up. Child controls (the hover archive
      // button) retain gesture precedence over this row gesture.
      .gesture(
        activationGesture,
        including: isArchivedEntry || isDragPreview || !activatesOnMouseDown ? .none : .all
      )
      .onTapGesture {
        if isArchivedEntry {
          onRestoreRequest()
          return
        }
        guard !activatesOnMouseDown else { return }
        onActivate()
      }
      .foregroundStyle(isSelected ? Color.primary : .secondary)
    }
    .contextMenu {
      if isArchivedEntry {
        Button {
          onRestoreRequest()
        } label: {
          Label("Restore", systemImage: "arrow.uturn.backward")
            .labelStyle(.titleAndIcon)
        }
      } else {
        Button {
          onRename()
        } label: {
          Label("Rename", systemImage: "pencil")
            .labelStyle(.titleAndIcon)
        }
        Button {
          onArchive()
        } label: {
          Label("Archive", systemImage: "archivebox")
            .labelStyle(.titleAndIcon)
        }
        SidebarUnreadToggleButton(
          isUnread: isUnread(),
          onMarkRead: onMarkRead,
          onMarkUnread: onMarkUnread
        )
      }
    }
  }

  /// Activate a chat as soon as the primary pointer goes down. Keeping this
  /// as a row gesture (rather than an overlay) preserves child button and
  /// context-menu hit testing.
  private var activationGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { _ in
        onActivate()
      }
  }
}
