import CodevisorCore
import SwiftUI

struct BotSectionHeader: View {
  let section: BotSection
  let isExpanded: Bool
  let isDropTarget: Bool
  let actions: BotSidebarRowActions

  var body: some View {
    SidebarSectionHeader(title: section.name, isExpanded: isExpanded) { actions.toggleSection(section.id) }
      .background(RoundedRectangle.sidebarRow.fill(RowSelectionStyle.fill(isSelected: false, isHovered: isDropTarget)))
      .contextMenu {
        Button("Rename Section…", systemImage: "pencil") { actions.renameSection(section) }
        Divider()
        Button("Delete Section", systemImage: "trash", role: .destructive) { actions.deleteSection(section) }
      }
  }
}
