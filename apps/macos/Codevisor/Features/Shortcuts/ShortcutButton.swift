import SwiftUI

struct ShortcutButton: View {
  private let definition: ShortcutDefinition
  private let title: String
  private let action: () -> Void

  init(_ id: ShortcutID, title: String? = nil, action: @escaping () -> Void) {
    definition = ShortcutCatalog.definition(for: id)
    self.title = title ?? definition.title
    self.action = action
  }

  var body: some View {
    Button(title, action: action)
      .keyboardShortcut(definition.combo?.keyboardShortcut)
  }
}

extension View {
  func shortcut(_ id: ShortcutID) -> some View {
    keyboardShortcut(ShortcutCatalog.combo(for: id)?.keyboardShortcut)
  }
}
