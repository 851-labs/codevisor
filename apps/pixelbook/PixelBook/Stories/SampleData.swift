import Foundation
import SwiftUI

/// A flat item for the plain stories.
struct Language: Identifiable, Hashable {
  let id: String
  var name: String { id }
}

/// A command for the rich-row story.
struct Command: Identifiable, Hashable {
  let id: String
  let title: String
  let symbol: String
  let shortcut: KeyboardShortcut?
}

/// Grouped items for the group, favorites, and footer stories.
struct Harness: Identifiable, Hashable {
  let id: String
  let name: String
  let models: [Model]
}

struct Model: Identifiable, Hashable {
  let id: String
  let name: String
}

enum SampleData {
  static let languages = [
    "Swift", "Kotlin", "Rust", "Go", "TypeScript", "Python", "Ruby", "Elixir", "Haskell", "Zig", "C", "C++",
  ].map(Language.init(id:))

  /// Enough languages to overflow the list's maximum height.
  static let manyLanguages = [
    "Swift", "Kotlin", "Rust", "Go", "TypeScript", "Python", "Ruby", "Elixir", "Haskell", "Zig", "C", "C++",
    "C#", "Java", "Scala", "Clojure", "OCaml", "F#", "Erlang", "Dart", "Lua", "Perl", "PHP", "R", "Julia",
    "Nim", "Crystal", "Gleam", "Roc", "Odin", "V", "D", "Fortran", "COBOL", "Lisp", "Scheme", "Prolog",
  ].map(Language.init(id:))

  static let commands = [
    Command(id: "new-chat", title: "New Chat", symbol: "plus.bubble", shortcut: KeyboardShortcut("n")),
    Command(id: "open-project", title: "Open Project…", symbol: "folder", shortcut: KeyboardShortcut("o")),
    Command(id: "toggle-sidebar", title: "Toggle Sidebar", symbol: "sidebar.left", shortcut: KeyboardShortcut("0")),
    Command(
      id: "previous-tab", title: "Previous Tab", symbol: "arrow.left.square",
      shortcut: KeyboardShortcut("[", modifiers: [.command, .shift])
    ),
    Command(id: "compact", title: "Compact Transcript", symbol: "arrow.down.right.and.arrow.up.left", shortcut: nil),
    Command(id: "review", title: "Review Diff", symbol: "checkmark.rectangle.stack", shortcut: nil),
    Command(id: "settings", title: "Settings…", symbol: "gearshape", shortcut: KeyboardShortcut(",")),
  ]

  static let harnesses = [
    Harness(
      id: "claude-code",
      name: "Claude Code",
      models: [
        Model(id: "opus-1m", name: "Opus (1M context)"),
        Model(id: "sonnet", name: "Sonnet"),
        Model(id: "haiku", name: "Haiku"),
      ]
    ),
    Harness(
      id: "codex",
      name: "Codex",
      models: [
        Model(id: "gpt-5", name: "GPT-5"),
        Model(id: "gpt-5-codex", name: "GPT-5 Codex"),
        Model(id: "o3", name: "o3"),
      ]
    ),
    Harness(
      id: "gemini",
      name: "Gemini CLI",
      models: [
        Model(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro"),
        Model(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash"),
      ]
    ),
  ]

  static let longTitles = [
    Language(id: "anthropic/claude-opus-4-1-20250805-extended-thinking-1m-context-preview"),
    Language(id: "openai/gpt-5-codex-2025-09-15-reasoning-effort-high-background-mode"),
    Language(id: "Short"),
  ]

  static func many(_ count: Int) -> [Language] {
    (1...count).map { Language(id: "Item \($0)") }
  }
}
