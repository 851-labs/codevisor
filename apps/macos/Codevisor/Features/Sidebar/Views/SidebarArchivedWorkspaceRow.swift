import SwiftUI

struct SidebarArchivedWorkspaceRow: View {
  let name: String
  let subtitle: String?
  let icon: SidebarWorkspaceIcon
  let store: SessionStore?
  let isSelected: Bool
  let isReordering: Bool
  let onActivate: () -> Void
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
