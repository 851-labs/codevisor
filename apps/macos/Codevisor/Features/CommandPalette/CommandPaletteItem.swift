import SwiftUI

struct CommandPaletteItem: Identifiable {
  enum Icon {
    case symbol(String)
    case harness(String?)
    case workspace(SidebarWorkspaceIcon)
  }

  let id: String
  let title: String
  var subtitle: String? = nil
  var icon: Icon? = nil
  var shortcut: KeyboardShortcut? = nil
  var searchTerms: [String] = []
  let perform: @MainActor () -> Void

  init(
    id: String, title: String, subtitle: String? = nil, icon: Icon? = nil,
    shortcut: KeyboardShortcut? = nil, searchTerms: [String] = [], perform: @escaping @MainActor () -> Void
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.shortcut = shortcut
    self.searchTerms = searchTerms
    self.perform = perform
  }

  init(
    _ title: String, systemImage: String, shortcut: KeyboardShortcut? = nil,
    perform: @escaping @MainActor () -> Void
  ) {
    self.init(id: title, title: title, icon: .symbol(systemImage), shortcut: shortcut, perform: perform)
  }

  init(_ shortcut: ShortcutID, systemImage: String, perform: @escaping @MainActor () -> Void) {
    let definition = ShortcutCatalog.definition(for: shortcut)
    id = shortcut.rawValue
    title = definition.title
    icon = .symbol(systemImage)
    self.shortcut = definition.combo?.keyboardShortcut
    self.perform = perform
  }
}
