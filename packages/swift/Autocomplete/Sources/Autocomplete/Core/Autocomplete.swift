/// Searchable menus and inline suggestions with one semantic interaction engine.
///
/// Compose a `Menu` from selection-bound `Picker`s and `Action`s, or use
/// `Suggestions` inline. The package owns filtering, navigation, favorites,
/// accessibility, and sizing. See the package README for complete examples.
public enum Autocomplete {}

extension Autocomplete {
  enum KeyCommand: Sendable, Hashable {
    case moveUp, moveDown, moveToFirst, moveToLast, accept, dismiss
  }
}
