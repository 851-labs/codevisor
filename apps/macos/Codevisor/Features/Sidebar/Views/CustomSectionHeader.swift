import CodevisorCore
import SwiftUI

struct CustomSectionHeader: View {
  let section: CustomSection
  let isExpanded: Bool
  let onToggle: () -> Void
  let actions: CustomSectionActions

  var body: some View {
    SidebarSectionHeader(title: section.name, isExpanded: isExpanded, onToggle: onToggle)
      .contextMenu {
        Button(action: actions.rename) {
          Label("Rename Section…", systemImage: "pencil")
            .labelStyle(.titleAndIcon)
        }
        Button(action: actions.moveUp) {
          Label("Move Up", systemImage: "arrow.up")
            .labelStyle(.titleAndIcon)
        }
        .disabled(!actions.canMoveUp)
        Button(action: actions.moveDown) {
          Label("Move Down", systemImage: "arrow.down")
            .labelStyle(.titleAndIcon)
        }
        .disabled(!actions.canMoveDown)
        Divider()
        Button(role: .destructive, action: actions.delete) {
          Label("Delete Section", systemImage: "trash")
            .labelStyle(.titleAndIcon)
        }
      }
  }
}
