import SwiftUI

struct ShortcutButton: View {
  private let definition: ShortcutDefinition
  private let action: () -> Void

  init(_ id: ShortcutID, action: @escaping () -> Void) {
    definition = ShortcutCatalog.definition(for: id)
    self.action = action
  }

  var body: some View {
    Button(definition.title, action: action)
      .keyboardShortcut(definition.combo?.keyboardShortcut)
  }
}

extension View {
  func shortcut(_ id: ShortcutID) -> some View {
    keyboardShortcut(ShortcutCatalog.combo(for: id)?.keyboardShortcut)
  }
}
