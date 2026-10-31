import CodevisorCore
import SwiftUI

struct CustomSectionHeader: View {
  let section: CustomSection
  let isExpanded: Bool
  let isDropTarget: Bool
  let onToggle: () -> Void
  let onRename: () -> Void
  let onDelete: () -> Void

  var body: some View {
    SidebarSectionHeader(title: section.name, isExpanded: isExpanded, onToggle: onToggle)
      .background(SidebarDropHighlight(isActive: isDropTarget))
      .contextMenu {
        Button(action: onRename) {
          Label("Rename Section…", systemImage: "pencil")
            .labelStyle(.titleAndIcon)
        }
        Divider()
        Button(role: .destructive, action: onDelete) {
          Label("Delete Section", systemImage: "trash")
            .labelStyle(.titleAndIcon)
        }
      }
  }
}
