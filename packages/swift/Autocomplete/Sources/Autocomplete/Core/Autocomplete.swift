/// Filterable, keyboard-navigable pickers composed the way SwiftUI composes
/// views. The shape follows Base UI's Autocomplete:
///
/// ```swift
/// Autocomplete.Root(highlight: highlight, onDismiss: { isPresented = false }) {
///   Autocomplete.Input(text: $query, prompt: "Filter models")
///   Autocomplete.List(height: listHeight) {
///     Autocomplete.Group("Favorites") {
///       ForEach(favorites) { item in
///         Autocomplete.Item(id: item.id, action: { choose(item) }) { Text(item.name) }
///       }
///     }
///   }
///   Autocomplete.Footer(id: .manage, action: openSettings) { Text("Manage Harnesses…") }
/// }
/// ```
///
/// `Root` owns the keyboard (arrows, ⌃N/⌃P, Return, Escape) and the
/// highlight; `Item`s register themselves in tree order, so any mix of
/// groups, conditionals, and `ForEach` works. The state types in `Core/`
/// are platform-neutral; the views are AppKit-hosted SwiftUI.
public enum Autocomplete {}

public extension Autocomplete {
  /// Navigation intents, independent of where they come from: the popup's
  /// key monitor, the input's text-command routing, or a text editor that
  /// owns the keyboard while an inline popup is showing.
  enum KeyCommand: Sendable, Hashable {
    case moveUp
    case moveDown
    case moveToFirst
    case moveToLast
    case accept
    case dismiss
  }
}
