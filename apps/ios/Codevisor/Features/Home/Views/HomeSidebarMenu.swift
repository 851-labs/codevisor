import Foundation

struct HomeSidebarMenu {
  struct Item {
    enum Kind {
      case action(() -> Void)
      case choice(isSelected: Bool, () -> Void)
      case submenu(HomeSidebarMenu)
    }

    let title: String
    var systemImage: String?
    var isDestructive = false
    let kind: Kind

    static func action(
      _ title: String, systemImage: String, isDestructive: Bool = false, perform: @escaping () -> Void
    ) -> Self {
      Self(title: title, systemImage: systemImage, isDestructive: isDestructive, kind: .action(perform))
    }

    static func choice(_ title: String, isSelected: Bool, perform: @escaping () -> Void) -> Self {
      Self(title: title, kind: .choice(isSelected: isSelected, perform))
    }

    static func submenu(_ title: String, systemImage: String, _ menu: HomeSidebarMenu) -> Self {
      Self(title: title, systemImage: systemImage, kind: .submenu(menu))
    }

    static func unread(isUnread: Bool, setUnread: @escaping (Bool) -> Void) -> Self {
      .action(isUnread ? "Mark as Read" : "Mark as Unread", systemImage: isUnread ? "message" : "message.badge") {
        setUnread(!isUnread)
      }
    }
  }

  var groups: [[Item]] = []

  var isEmpty: Bool { groups.allSatisfy(\.isEmpty) }

  mutating func add(_ items: [Item]) {
    guard !items.isEmpty else { return }
    groups.append(items)
  }

  mutating func add(_ item: Item) {
    add([item])
  }
}
