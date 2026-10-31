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
        Button("Rename Section…", systemImage: "pencil", action: onRename)
        Divider()
        Button("Delete Section", systemImage: "trash", role: .destructive, action: onDelete)
      }
  }
}
