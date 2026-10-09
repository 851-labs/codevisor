import CodevisorCore
import CodevisorUI
import SwiftUI

/// One workspace in the sidebar: its status, its name, and where it runs.
/// Its tabs live in the strip above the workspace's content.
struct SidebarWorkspaceRow: View {
  let name: String
  /// Where the workspace lives: a remote machine's name, or "This Mac" for
  /// local ones. Nil only when the workspace's machine is unknown.
  let machineName: String?
  let status: SidebarWorkspaceStatus
  let isSelected: Bool
  let isReordering: Bool
  let onActivate: () -> Void
  let onNewTab: () -> Void
  let onRename: () -> Void
  let onArchive: () -> Void
  /// Latches one activation per press; resets when the gesture ends or is
  /// cancelled.
  @GestureState private var isPressed = false

  var body: some View {
    HoverableRow(
      isSelected: isSelected,
      isHoverEnabled: !isReordering,
      isHoverForced: false
    ) { isHovered in
      HStack(spacing: 7) {
        SidebarWorkspaceRowLabel(name: name, machineName: isHovered ? nil : machineName, status: status)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
          // Only the label activates on pointer-down. The archive button is
          // a sibling, so pressing it cannot select the row first.
          .gesture(
            DragGesture(minimumDistance: 0)
              .updating($isPressed) { _, isPressed, _ in
                guard !isPressed else { return }
                isPressed = true
                onActivate()
              }
          )
        if isHovered {
          Button(action: onArchive) {
            Image(systemName: "archivebox")
              .font(.caption)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Archive workspace")
          .accessibilityLabel("Archive \(SidebarWorkspaceRowLabel.title(for: name))")
          .frame(width: 24, height: 14, alignment: .trailing)
        }
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .contextMenu {
      Button(action: onNewTab) {
        Label("New Tab", systemImage: "plus")
          .labelStyle(.titleAndIcon)
      }
      Divider()
      Button(action: onRename) {
        Label("Rename", systemImage: "pencil")
          .labelStyle(.titleAndIcon)
      }
      Button(action: onArchive) {
        Label("Archive", systemImage: "archivebox")
          .labelStyle(.titleAndIcon)
      }
    }
  }
}

/// The row's icon, name, and machine, shared with the reorder ghost so the
/// lifted row and its stand-in never drift apart in style.
struct SidebarWorkspaceRowLabel: View {
  let name: String
  let machineName: String?
  let status: SidebarWorkspaceStatus

  static func title(for name: String) -> String {
    name.isEmpty ? "Workspace" : name
  }

  var body: some View {
    HStack(spacing: 7) {
      SidebarWorkspaceStatusIcon(status: status)
      Text(Self.title(for: name))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let machineName {
        Text(machineName)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .layoutPriority(-1)
      }
    }
    // Native sidebar rows keep the label color whether or not they are
    // selected; only the glyph and trailing context read as secondary.
    .foregroundStyle(.primary)
    .accessibilityElement(children: .combine)
  }
}

/// What a workspace's chats and agent terminals are doing, collapsed to the
/// one state its row shows. Precedence matches a chat's own leading icon.
enum SidebarWorkspaceStatus: Equatable {
  case error
  case waitingOnUser
  case working
  case unread
  case idle
}

private struct SidebarWorkspaceStatusIcon: View {
  let status: SidebarWorkspaceStatus
  @Environment(\.theme) private var theme

  var body: some View {
    Group {
      switch status {
      case .error:
        ErrorUnreadBadge(color: theme.statusError)
      case .waitingOnUser:
        ActionRequiredIndicator(color: theme.statusError)
      case .working:
        AgentStatusIndicator(status: .working)
      case .unread:
        AgentStatusIndicator(status: .unread)
      case .idle:
        // A quiet dot, smaller than the unread badge so the two never read
        // as the same state.
        Circle()
          .fill(.tertiary)
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)
      }
    }
    .frame(width: 18)
  }
}
