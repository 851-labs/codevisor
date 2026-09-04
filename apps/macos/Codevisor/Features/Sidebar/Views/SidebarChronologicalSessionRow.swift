import CodevisorCore
import SwiftUI

/// The Agents-list chat row: title plus a project/worktree subtitle.
struct SidebarChronologicalSessionRow: View {
  @Environment(AppEnvironment.self) private var environment

  let session: ChatSession
  let project: Project
  let store: SessionStore?
  var isDragPreview = false
  var isArchivedEntry = false
  var hierarchyDepth = 0
  var hierarchyIndent: CGFloat = 8
  var showsProjectName = true
  let isSelected: Bool
  /// Manual-order chat rows attach this gesture alongside their native
  /// drag source so activation does not prevent drag-to-reorder.
  let activatesOnMouseDown: Bool
  let isReordering: Bool
  let titleFont: Font
  /// Deferred so the unread state is read when the context menu opens,
  /// exactly as the previous inline builder did.
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
      HStack(spacing: 7) {
        ChatSessionLeadingIcon(session: session, store: store, activityColor: .secondary)
          .frame(width: 18)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(session.title)
            .font(titleFont)
            .lineLimit(1)
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
      .foregroundStyle(isSelected ? Color.primary : .secondary)
      .gesture(
        activationGesture,
        including: !isArchivedEntry && activatesOnMouseDown ? .all : .none
      )
      .onTapGesture {
        if isArchivedEntry {
          onRestoreRequest()
          return
        }
        guard !activatesOnMouseDown else { return }
        onActivate()
      }
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

  private var subtitle: String {
    let machineName = environment.machines.fleetMachineName(for: session.serverId)
    // A scratch folder's generated name says nothing about the chat; a
    // no-project chat shows only its machine.
    let projectName: String? = project.isScratch ? nil : project.name

    if !showsProjectName {
      let context = session.worktreeName.flatMap { $0.isEmpty ? nil : $0 } ?? projectName
      return [context, machineName]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    return [projectName, session.worktreeName, machineName]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: " · ")
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
