/// Searchable, keyboard-navigable pickers. `Menu` owns filtering, empty states,
/// section dividers, sizing, and navigation for a collection of options:
///
/// ```swift
/// Autocomplete.Menu(
///   sections: [
///     .init(id: "projects", items: projects),
///     .init(id: "actions", items: [
///       Autocomplete.Option(id: .newProject, title: "New Project…", action: createProject)
///     ])
///   ],
///   searchAccessibilityLabel: "Search projects",
///   onDismiss: { isPresented = false }
/// )
/// ```
///
/// The composable primitives remain available for custom presentations.
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
