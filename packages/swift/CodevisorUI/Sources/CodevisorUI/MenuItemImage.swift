#if os(macOS)
  import AppKit

  @MainActor
  public enum MenuItemImage {
    public static func show(_ systemName: String, on item: NSMenuItem) {
      item.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
      reveal(item)
    }

    public static func reveal(_ item: NSMenuItem) {
      guard #available(macOS 27.0, *) else { return }
      item.preferredImageVisibility = .visible
    }
  }
#endif
