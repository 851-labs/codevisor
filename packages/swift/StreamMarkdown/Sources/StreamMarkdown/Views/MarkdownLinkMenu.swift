#if canImport(AppKit)
  import AppKit

  @MainActor
  public enum MarkdownLinkMenu {
    public static func menu(for items: [MarkdownLinkMenuItem]) -> NSMenu {
      let menu = NSMenu()
      for item in items { menu.addItem(menuItem(for: item)) }
      return menu
    }

    private static func menuItem(for item: MarkdownLinkMenuItem) -> NSMenuItem {
      switch item {
      case let .action(title, systemImage, perform): MarkdownMenuItem(title, systemImage: systemImage, handler: perform)
      case .separator: .separator()
      }
    }
  }

  @MainActor
  final class MarkdownMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, systemImage: String, handler: @escaping @MainActor () -> Void) {
      self.handler = handler
      super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
      target = self
      image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func runHandler() { handler() }
  }
#endif
