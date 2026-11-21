import CodevisorCore
import SwiftUI

struct HomeSidebarSectionMenu: View {
  let section: CustomSection
  let sections: [CustomSection]
  let actions: HomeSidebarSectionActions

  private var index: Int { sections.firstIndex { $0.id == section.id } ?? 0 }

  var body: some View {
    Button("Rename…", systemImage: "pencil") { actions.rename(section) }
    if index > 0 {
      Button("Move Up", systemImage: "arrow.up") { actions.reorder(section.id, index - 1) }
    }
    if index < sections.count - 1 {
      Button("Move Down", systemImage: "arrow.down") { actions.reorder(section.id, index + 1) }
    }
    Divider()
    Button("Delete Section", systemImage: "trash", role: .destructive) { actions.delete(section) }
  }
}
