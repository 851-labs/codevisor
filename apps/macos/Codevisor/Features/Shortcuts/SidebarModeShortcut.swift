import CodevisorUI

enum SidebarModeShortcut {
  static func id(for mode: SidebarMode) -> ShortcutID {
    switch mode {
    case .bots: .switchToBots
    case .code: .switchToCode
    }
  }

  static func help(for mode: SidebarMode) -> String {
    "\(mode.title) \(ShortcutCatalog.display(for: id(for: mode)))"
  }
}
