#if os(macOS)
  import AppKit
  import SwiftUI

  struct CloudSignInMenuItem {
    let title: String
    let image: NSImage?
    let action: () -> Void
  }

  struct CloudSignInMenuButton: NSViewRepresentable {
    let title: String
    let items: [CloudSignInMenuItem]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MenuPushButton {
      let button = MenuPushButton(title: title, target: context.coordinator, action: #selector(Coordinator.open(_:)))
      button.bezelStyle = .push
      button.controlSize = .regular
      button.setContentHuggingPriority(.required, for: .horizontal)
      return button
    }

    func updateNSView(_ button: MenuPushButton, context: Context) {
      context.coordinator.items = items
      button.isEnabled = context.environment.isEnabled
      button.title = title
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuPushButton, context: Context) -> CGSize? {
      nsView.intrinsicContentSize
    }

    final class Coordinator: NSObject {
      var items: [CloudSignInMenuItem] = []

      @objc func open(_ sender: NSButton) {
        let menu = NSMenu()
        for (index, item) in items.enumerated() {
          menu.addItem(menuItem(item, tag: index))
        }
        menu.popUp(positioning: nil, at: menuOrigin(menu, below: sender), in: sender)
      }

      @objc func choose(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }

        items[sender.tag].action()
      }

      private func menuItem(_ item: CloudSignInMenuItem, tag: Int) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.tag = tag
        menuItem.image = item.image
        if #available(macOS 27.0, *) {
          menuItem.preferredImageVisibility = .visible
        }
        return menuItem
      }

      private func menuOrigin(_ menu: NSMenu, below button: NSButton) -> NSPoint {
        let gap: CGFloat = 4
        let x = button.bounds.maxX - menu.size.width
        if button.isFlipped {
          return NSPoint(x: x, y: button.bounds.maxY + gap)
        }
        return NSPoint(x: x, y: -gap)
      }
    }

    final class MenuPushButton: NSButton {
      override func accessibilityRole() -> NSAccessibility.Role? { .menuButton }
    }
  }

#endif
