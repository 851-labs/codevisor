import CodevisorCore
import Foundation

struct HomeSidebarSectionMenu {
  let section: CustomSection
  let sections: [CustomSection]
  let actions: HomeSidebarSectionActions

  private var index: Int { sections.firstIndex { $0.id == section.id } ?? 0 }

  var menu: HomeSidebarMenu {
    var menu = HomeSidebarMenu()
    menu.add([.action("Rename…", systemImage: "pencil") { actions.rename(section) }] + moves)
    menu.add(.action("Delete Section", systemImage: "trash", isDestructive: true) { actions.delete(section) })
    return menu
  }

  private var moves: [HomeSidebarMenu.Item] {
    var moves: [HomeSidebarMenu.Item] = []
    if index > 0 {
      moves.append(.action("Move Up", systemImage: "arrow.up") { actions.reorder(section.id, index - 1) })
    }
    if index < sections.count - 1 {
      moves.append(.action("Move Down", systemImage: "arrow.down") { actions.reorder(section.id, index + 1) })
    }
    return moves
  }
}
