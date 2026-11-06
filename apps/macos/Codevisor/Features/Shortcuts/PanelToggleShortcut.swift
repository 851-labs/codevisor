enum PanelToggleShortcut {
  case sidebar
  case inspector

  var id: ShortcutID {
    switch self {
    case .sidebar: .toggleSidebar
    case .inspector: .toggleInspector
    }
  }

  func title(isVisible: Bool) -> String {
    "\(isVisible ? "Hide" : "Show") \(panelName)"
  }

  func help(isVisible: Bool) -> String {
    "\(title(isVisible: isVisible)) \(ShortcutCatalog.display(for: id))"
  }

  var searchTerm: String {
    "Toggle \(panelName)"
  }

  private var panelName: String {
    switch self {
    case .sidebar: "Sidebar"
    case .inspector: "Inspector"
    }
  }
}
