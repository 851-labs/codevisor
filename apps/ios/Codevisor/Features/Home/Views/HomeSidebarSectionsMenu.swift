import CodevisorCore
import SwiftUI

struct HomeSidebarSectionsMenu: View {
  let sections: [CustomSection]
  let actions: HomeSidebarSectionActions

  var body: some View {
    Button("New Section…", systemImage: "folder.badge.plus") { actions.create(nil) }
    if !sections.isEmpty {
      Menu {
        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
          Menu(section.name) { sectionActions(section, at: index) }
        }
      } label: {
        Label("Sections", systemImage: "folder")
      }
    }
  }

  @ViewBuilder
  private func sectionActions(_ section: CustomSection, at index: Int) -> some View {
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
