import Foundation

enum SyntaxLanguage: String, CaseIterable, Sendable {
  case bash, c, cpp, css, diff, go, html, java, javascript, json, jsx, kotlin
  case markdown, python, ruby, rust, sql, swift, toml, tsx, typescript, yaml

  static func resolve(_ value: String?) -> SyntaxLanguage? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let language = SyntaxLanguage(rawValue: normalized) { return language }
    return aliases[normalized]
  }

  private static let aliases: [String: SyntaxLanguage] = [
    "js": .javascript, "mjs": .javascript, "cjs": .javascript,
    "ts": .typescript, "mts": .typescript, "cts": .typescript,
    "py": .python, "rb": .ruby, "golang": .go, "kt": .kotlin,
    "md": .markdown, "sh": .bash, "shell": .bash, "zsh": .bash,
    "yml": .yaml, "c++": .cpp, "jsonc": .json, "patch": .diff,
  ]

  var textMateRootScope: String {
    switch self {
    case .bash: "source.shell"
    case .c: "source.c"
    case .cpp: "source.cpp"
    case .css: "source.css"
    case .diff: "source.diff"
    case .go: "source.go"
    case .html: "text.html.basic"
    case .java: "source.java"
    case .javascript: "source.js"
    case .json: "source.json"
    case .jsx: "source.js.jsx"
    case .kotlin: "source.kotlin"
    case .markdown: "text.html.markdown"
    case .python: "source.python"
    case .ruby: "source.ruby"
    case .rust: "source.rust"
    case .sql: "source.sql"
    case .swift: "source.swift"
    case .toml: "source.toml"
    case .tsx: "source.tsx"
    case .typescript: "source.ts"
    case .yaml: "source.yaml"
    }
  }

}
