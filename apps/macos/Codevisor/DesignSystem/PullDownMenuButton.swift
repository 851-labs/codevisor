import AppKit
import SwiftUI

struct PullDownMenuButton: NSViewRepresentable {
  struct Item {
    let title: String
    let systemImage: String
    let action: () -> Void
  }

  let help: String
  let items: [Item]

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSPopUpButton {
    let button = FullFramePopUpButton(frame: .zero, pullsDown: true)
    button.isBordered = false
    button.imagePosition = .imageOnly
    (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
    return button
  }

  func updateNSView(_ button: NSPopUpButton, context: Context) {
    let coordinator = context.coordinator
    button.toolTip = help
    coordinator.items = items
    guard coordinator.menuSignature != menuSignature else { return }

    button.menu = menu(target: coordinator)
    coordinator.menuSignature = menuSignature
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
    proposal.replacingUnspecifiedDimensions()
  }

  private var menuSignature: [String] {
    items.map { "\($0.title)\n\($0.systemImage)" }
  }

  private func menu(target: Coordinator) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
    for (index, item) in items.enumerated() {
      menu.addItem(menuItem(for: item, tag: index, target: target))
    }
    return menu
  }

  private func menuItem(for item: Item, tag: Int, target: Coordinator) -> NSMenuItem {
    let menuItem = NSMenuItem(title: item.title, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
    menuItem.target = target
    menuItem.tag = tag
    menuItem.image = NSImage(systemSymbolName: item.systemImage, accessibilityDescription: nil)
    if #available(macOS 27.0, *) {
      menuItem.preferredImageVisibility = .visible
    }
    return menuItem
  }

  final class Coordinator: NSObject {
    var items: [Item] = []
    var menuSignature: [String]?

    @objc func choose(_ sender: NSMenuItem) {
      guard items.indices.contains(sender.tag) else { return }

      items[sender.tag].action()
    }
  }

  private final class FullFramePopUpButton: NSPopUpButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
  }
}
