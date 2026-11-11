import AppKit

enum WindowShortcut {
  private static let ids: [ShortcutID] = [.switchToBots, .switchToCode, .toggleSidebar, .toggleInspector]

  static func matches(_ event: NSEvent) -> Bool {
    ids.contains { ShortcutCatalog.combo(for: $0)?.matches(event) == true }
  }
}
