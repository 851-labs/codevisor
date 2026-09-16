import CTreeSitter
import CodeHighlighterGrammars
import Foundation

enum TreeSitterError: Error, CustomStringConvertible {
  case unavailable(String)
  case query(String, UInt32, TSQueryError)
  case predicate(String)
  case invalidEdit
  case parse

  var description: String {
    switch self {
    case .unavailable(let name): "Unavailable Tree-sitter grammar: \(name)"
    case .query(let name, let offset, let error): "Invalid \(name) query at byte \(offset): \(error)"
    case .predicate(let name): "Unsupported Tree-sitter predicate: \(name)"
    case .invalidEdit: "Invalid document edit"
    case .parse: "Tree-sitter parsing failed or was cancelled"
    }
  }
}

/// Queries and generated languages are immutable. Every execution owns its cursor;
/// every document owns its parser and trees. Only this immutable registry is shared.
final class TreeSitterGrammar: @unchecked Sendable {
  let name: String
  let language: OpaquePointer
  let highlights: TreeSitterQuery
  let injections: TreeSitterQuery?
  let locals: TreeSitterQuery?

  private static let cache = Cache()
  private final class Cache: @unchecked Sendable {
    let lock = NSLock()
    var values: [String: TreeSitterGrammar] = [:]
  }

  static func load(_ name: String) throws -> TreeSitterGrammar {
    try cache.lock.withLock {
      if let existing = cache.values[name] { return existing }
      let grammar = try TreeSitterGrammar(name: name)
      cache.values[name] = grammar
      return grammar
    }
  }

  private init(name: String) throws {
    self.name = name
    let pointer: OpaquePointer?
    switch name {
    case "bash": pointer = tree_sitter_bash()
    case "c": pointer = tree_sitter_c()
    case "cpp": pointer = tree_sitter_cpp()
    case "css": pointer = tree_sitter_css()
    case "diff": pointer = tree_sitter_diff()
    case "go": pointer = tree_sitter_go()
    case "html": pointer = tree_sitter_html()
    case "java": pointer = tree_sitter_java()
    case "javascript", "jsx": pointer = tree_sitter_javascript()
    case "json": pointer = tree_sitter_json()
    case "kotlin": pointer = tree_sitter_kotlin()
    case "markdown": pointer = tree_sitter_markdown()
    case "markdown_inline": pointer = tree_sitter_markdown_inline()
    case "python": pointer = tree_sitter_python()
    case "ruby": pointer = tree_sitter_ruby()
    case "rust": pointer = tree_sitter_rust()
    case "sql": pointer = tree_sitter_sql()
    case "swift": pointer = tree_sitter_swift()
    case "toml": pointer = tree_sitter_toml()
    case "tsx": pointer = tree_sitter_tsx()
    case "typescript": pointer = tree_sitter_typescript()
    case "yaml": pointer = tree_sitter_yaml()
    default: pointer = nil
    }
    guard let pointer else { throw TreeSitterError.unavailable(name) }
    language = pointer
    var bases = [name]
    if name == "cpp" { bases = ["c", "cpp"] }
    if ["javascript", "jsx", "typescript", "tsx"].contains(name) {
      bases = ["javascript"]
      if name == "typescript" || name == "tsx" { bases.append("typescript") }
    }
    func source(_ kind: String) throws -> String {
      var fragments = try bases.compactMap { base -> String? in
        guard let url = Bundle.module.url(forResource: kind, withExtension: "scm", subdirectory: "Queries/\(base)")
        else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
      }
      if kind == "highlights", ["javascript", "jsx", "tsx"].contains(name),
        let url = Bundle.module.url(
          forResource: "highlights-jsx", withExtension: "scm", subdirectory: "Queries/javascript")
      {
        fragments.append(try String(contentsOf: url, encoding: .utf8))
      }
      return fragments.joined(separator: "\n")
    }
    highlights = try TreeSitterQuery(language: pointer, source: source("highlights"), name: name)
    let injectionSource = try source("injections")
    injections =
      injectionSource.isEmpty ? nil : try TreeSitterQuery(language: pointer, source: injectionSource, name: name)
    let localSource = highlights.usesLocals ? try source("locals") : ""
    locals = localSource.isEmpty ? nil : try TreeSitterQuery(language: pointer, source: localSource, name: name)
  }
}
