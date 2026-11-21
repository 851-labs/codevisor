import CodevisorCore
import Foundation

enum HomeSidebarMoveToSectionMenu {
  static func item(
    currentSectionID: UUID?, sections: [CustomSection], move: @escaping (UUID?) -> Void,
    newSection: @escaping () -> Void
  ) -> HomeSidebarMenu.Item {
    var menu = HomeSidebarMenu()
    menu.add(.choice("No Section", isSelected: currentSectionID == nil) { move(nil) })
    menu.add(
      sections.map { section in .choice(section.name, isSelected: currentSectionID == section.id) { move(section.id) } }
    )
    menu.add(.action("New Section…", systemImage: "folder.badge.plus", perform: newSection))
    return .submenu("Move to Section", systemImage: "folder", menu)
  }

}
