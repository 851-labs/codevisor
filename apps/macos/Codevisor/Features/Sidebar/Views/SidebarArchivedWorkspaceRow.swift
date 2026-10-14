import SwiftUI

/// An archived workspace: the row's label in secondary colors, a hover
/// Restore button, and Restore in its menu. Clicking the row opens the
/// workspace read-only; restoring is a separate, deliberate step, since it
/// also brings back the worktree.
struct SidebarArchivedWorkspaceRow: View {
  let name: String
  let subtitle: String?
  let icon: SidebarWorkspaceIcon
  let store: SessionStore?
  let isSelected: Bool
  let isReordering: Bool
  /// Opens the workspace read-only.
  let onActivate: () -> Void
  /// Restores right away.
  let onRestore: () -> Void

  var body: some View {
    HoverableRow(isSelected: isSelected, isHoverEnabled: !isReordering) { isHovered in
      HStack(spacing: 7) {
        SidebarWorkspaceRowLabel(name: name, subtitle: subtitle, icon: icon, store: store)
          .foregroundStyle(.secondary)
          .opacity(0.8)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
          .onTapGesture(perform: onActivate)
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
          .accessibilityValue("Archived")
          .accessibilityAction(.default, onActivate)
          // Plain-title buttons: SwiftUI drops Label-built ones here.
          .accessibilityActions {
            Button("Restore", action: onRestore)
          }
        if isHovered {
          Button(action: onRestore) {
            Image(systemName: "arrow.uturn.backward")
              .font(.system(size: SidebarRowIcon.trailingSize, weight: SidebarRowIcon.weight))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Restore workspace")
          .frame(minWidth: 24, minHeight: 14, alignment: .trailing)
          // Covered by the row's Restore action, which does not depend on
          // hover.
          .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .contextMenu {
      Button(action: onRestore) {
        Label("Restore", systemImage: "arrow.uturn.backward")
          .labelStyle(.titleAndIcon)
      }
    }
  }
}
