import CodevisorCore
import CodevisorUI
import SwiftUI

/// One workspace row, either top-level or nested beneath its project.
/// Nested rows are disclosure-only; top-level workspace rows retain their
/// primary-chat activation behavior.
struct SidebarWorkspaceRow: View {
  let item: SidebarWorkspaceListItem
  let store: SessionStore?
  var isExpanded = false
  var onToggle: (() -> Void)? = nil
  let isSelected: Bool
  let isReordering: Bool
  let titleFont: Font
  /// Fleet context: the owning machine's name; nil hides it entirely.
  var machineName: String? = nil
  let onActivateSession: (ChatSession) -> Void
  let onArchive: () -> Void
  let onRename: () -> Void
  /// Nous mode only: adds a tab to this workspace (the sidebar's ⌘T).
  var onNewTab: (() -> Void)? = nil

  var body: some View {
    HoverableRow(
      isSelected: isSelected,
      isHoverEnabled: !isReordering,
      isHoverForced: false
    ) { isHovered in
      HStack(spacing: 7) {
        if let onToggle {
          Button(action: onToggle) {
            HStack(spacing: 7) {
              ZStack {
                Image(systemName: EntitySystemSymbol.workspace)
                  .foregroundStyle(.secondary)
                  .opacity(isHovered ? 0 : 1)
                Image(systemName: "chevron.right")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .rotationEffect(.degrees(isExpanded ? 90 : 0))
                  .opacity(isHovered ? 1 : 0)
              }
              .frame(width: 18)
              VStack(alignment: .leading, spacing: 1) {
                Text(title)
                  .font(titleFont)
                  .lineLimit(1)
                if let machineName {
                  Text(machineName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
              }
              Spacer(minLength: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(isExpanded ? "Collapse workspace" : "Expand workspace")
          .accessibilityLabel(
            isExpanded
              ? "Collapse \(item.workspace.name)"
              : "Expand \(item.workspace.name)"
          )
          if let session = item.primarySession, isHovered {
            SidebarSessionStatus(
              session: session,
              store: store,
              isHovered: true,
              onArchive: onArchive
            )
          }
        } else {
          Image(systemName: EntitySystemSymbol.workspace)
            .frame(width: 18)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text(title)
              .font(titleFont)
              .lineLimit(1)
            if let machineName {
              Text(machineName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
          }
          Spacer(minLength: 6)
        }
        if onToggle == nil, let session = item.primarySession {
          SidebarSessionStatus(
            session: session,
            store: store,
            isHovered: isHovered,
            onArchive: onArchive
          )
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .foregroundStyle(isSelected ? Color.primary : .secondary)
      .gesture(
        activationGesture,
        including: onToggle == nil ? .all : .none
      )
      .onTapGesture {
        guard onToggle == nil else { return }
        guard let session = item.primarySession else { return }
        onActivateSession(session)
      }
    }
    .contextMenu {
      if let onNewTab {
        Button {
          onNewTab()
        } label: {
          Label("New Tab", systemImage: "plus")
            .labelStyle(.titleAndIcon)
        }
        Divider()
      }
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
    }
  }

  /// Top-level workspace rows route through their primary chat. Match chat
  /// rows by doing that work on pointer-down; nested workspace rows remain
  /// disclosure-only and disable this gesture at the call site.
  private var activationGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { _ in
        guard let session = item.primarySession else { return }
        onActivateSession(session)
      }
  }

  /// Disclosure labels identify the workspace only. Project and worktree
  /// context belongs on each child chat, matching the iOS organization.
  private var title: String {
    item.workspace.name.isEmpty ? "Workspace" : item.workspace.name
  }
}
