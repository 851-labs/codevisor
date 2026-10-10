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
    let pointer = try Self.language(named: name)
    language = pointer
    let bases = TreeSitterQuerySources.bases(for: name)
    highlights = try TreeSitterQuery(
      language: pointer, source: TreeSitterQuerySources.source("highlights", for: name, bases: bases), name: name)
    let injectionSource = try TreeSitterQuerySources.source("injections", for: name, bases: bases)
    injections =
      injectionSource.isEmpty ? nil : try TreeSitterQuery(language: pointer, source: injectionSource, name: name)
    let localSource = highlights.usesLocals ? try TreeSitterQuerySources.source("locals", for: name, bases: bases) : ""
    locals = localSource.isEmpty ? nil : try TreeSitterQuery(language: pointer, source: localSource, name: name)
  }

  private static func language(named name: String) throws -> OpaquePointer {
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
    return pointer
  }
}
