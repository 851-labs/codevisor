import UIKit

enum HomeSidebarUIMenu {
  static func make(_ menu: HomeSidebarMenu, title: String = "") -> UIMenu {
    let groups = menu.groups.map { UIMenu(options: .displayInline, children: $0.map(element)) }
    return UIMenu(title: title, children: groups)
  }

  private static func element(_ item: HomeSidebarMenu.Item) -> UIMenuElement {
    let image = item.systemImage.flatMap { UIImage(systemName: $0) }
    switch item.kind {
    case let .action(perform):
      return UIAction(title: item.title, image: image, attributes: attributes(item)) { _ in perform() }
    case let .choice(isSelected, perform):
      return UIAction(title: item.title, image: image, state: isSelected ? .on : .off) { _ in perform() }
    case let .submenu(submenu):
      let groups = submenu.groups.map { UIMenu(options: .displayInline, children: $0.map(element)) }
      return UIMenu(title: item.title, image: image, children: groups)
    }
  }

  private static func attributes(_ item: HomeSidebarMenu.Item) -> UIMenuElement.Attributes {
    item.isDestructive ? .destructive : []
  }
}
