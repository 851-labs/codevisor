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
    // The optional-taking `keyboardShortcut` overload, never an `if` — see
    // the note on `View.shortcut(_:)` below.
    Button(definition.title, action: action)
      .keyboardShortcut(definition.combo?.keyboardShortcut)
  }
}

extension View {
  /// Applies a catalog shortcut to a control that supplies its own label —
  /// menu items with icons, for instance. Prefer `ShortcutButton` when the
  /// label is just the command's title. A command with no key equivalent
  /// leaves the control untouched.
  ///
  /// Deliberately *not* `@ViewBuilder` with an `if let`: branching wraps the
  /// item in `_ConditionalContent`, and SwiftUI resolves that one pass after
  /// it first bridges the enclosing `Menu` into its `NSMenu`. The key
  /// equivalents then land only on the second presentation, so the first open
  /// of a pull-down menu shows no shortcuts at all. Passing the optional
  /// straight through keeps the item's type static, so the `NSMenuItem` is
  /// built with its key equivalent already attached.
  func shortcut(_ id: ShortcutID) -> some View {
    keyboardShortcut(ShortcutCatalog.combo(for: id)?.keyboardShortcut)
  }
}
