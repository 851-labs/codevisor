import SwiftUI

/// A menu `Button` whose title and key equivalent both come from
/// `ShortcutCatalog`.
///
/// Every menu command goes through this, so the menu bar, the AppKit key
/// handlers, and the Settings ▸ Shortcuts list all read the same table. Items
/// whose definition has no combo simply render without a key equivalent.
struct ShortcutButton: View {
    private let definition: ShortcutDefinition
    private let action: () -> Void

    init(_ id: ShortcutID, action: @escaping () -> Void) {
        definition = ShortcutCatalog.definition(for: id)
        self.action = action
    }

    var body: some View {
        let button = Button(definition.title, action: action)
        if let combo = definition.combo {
            button.keyboardShortcut(combo.keyboardShortcut)
        } else {
            button
        }
    }
}

extension View {
    /// Applies a catalog shortcut to a control that supplies its own label —
    /// menu items with icons, for instance. Prefer `ShortcutButton` when the
    /// label is just the command's title. A command with no key equivalent
    /// leaves the control untouched.
    @ViewBuilder
    func shortcut(_ id: ShortcutID) -> some View {
        if let combo = ShortcutCatalog.combo(for: id) {
            keyboardShortcut(combo.keyboardShortcut)
        } else {
            self
        }
    }
}
