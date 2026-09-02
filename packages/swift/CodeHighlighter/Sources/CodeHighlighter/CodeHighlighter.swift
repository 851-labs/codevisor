import Foundation
import os

private let log = Logger(subsystem: "com.851labs.codevisor", category: "highlighting")

/// Native, incremental syntax highlighting for transcript code blocks and
/// diffs. The lexer is intentionally lexical rather than editor-grade: it
/// recognizes the language constructs that affect presentation, carries
/// multiline comment/string state between lines, and never executes JavaScript
/// or loads a runtime bundle on the rendering path.
public actor CodeHighlighter {
  /// One styled output run. A nil color inherits the code block's foreground.
  public struct Token: Sendable, Equatable, Codable {
    public let content: String
    public let color: String?

    public init(content: String, color: String?) {
      self.content = content
      self.color = color
    }
  }

  private struct ResultCacheKey: Hashable {
    let themeKey: String
    let themeRevision: UInt64
    let language: SyntaxLanguage
    let code: String
  }

  private struct ThemeEntry {
    let json: String
    let theme: NativeSyntaxTheme?
    let revision: UInt64
  }

  private struct SessionEntry {
    let document: NativeLexedDocument
    let revision: UInt64
  }

  public static let shared = CodeHighlighter()

  private var resultCache: [ResultCacheKey: [[Token]]] = [:]
  private var resultCacheOrder: [ResultCacheKey] = []
  private var themes: [String: ThemeEntry] = [:]
  private var themeRevision: UInt64 = 0
  private var sessions: [String: SessionEntry] = [:]
  private var sessionRevision: UInt64 = 0
  private let resultCacheLimit = 200
  private let sessionLimit = 32

  public init() {}

  /// Grammar name for a file path's extension, or nil when Codevisor does
  /// not support it. This is also used by the diff viewer.
  public static func language(forPath path: String) -> String? {
    let ext = (path as NSString).pathExtension.lowercased()
    guard !ext.isEmpty else { return nil }
    return extensionLanguages[ext]?.rawValue
  }

  private static let extensionLanguages: [String: SyntaxLanguage] = [
    "sh": .bash, "bash": .bash, "zsh": .bash,
    "c": .c, "h": .c,
    "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp,
    "css": .css,
    "diff": .diff, "patch": .diff,
    "go": .go,
    "html": .html, "htm": .html,
    "java": .java,
    "js": .javascript, "mjs": .javascript, "cjs": .javascript,
    "json": .json, "jsonc": .json,
    "jsx": .jsx,
    "kt": .kotlin, "kts": .kotlin,
    "md": .markdown, "markdown": .markdown,
    "py": .python,
    "rb": .ruby,
    "rs": .rust,
    "sql": .sql,
    "swift": .swift,
    "toml": .toml,
    "tsx": .tsx,
    "ts": .typescript, "mts": .typescript, "cts": .typescript,
    "yml": .yaml, "yaml": .yaml,
  ]

  /// Highlights source using a VS Code/Shiki theme document.
  ///
  /// `sessionID` gives a growing streaming block a stable identity. When the
  /// next snapshot arrives, unchanged lines and their ending lexer states are
  /// reused. Set `isComplete` for the final snapshot so the session is
  /// released and the styled result enters the bounded settled-result cache.
  public func highlight(
    code: String,
    language: String?,
    themeKey: String,
    themeJSON: String,
    sessionID: String? = nil,
    isComplete: Bool = true
  ) -> [[Token]]? {
    guard let language = SyntaxLanguage.resolve(language) else { return nil }
    guard let (theme, themeRevision) = theme(for: themeKey, json: themeJSON) else {
      if isComplete, let sessionID { sessions.removeValue(forKey: sessionID) }
      return nil
    }

    let cacheKey = ResultCacheKey(
      themeKey: themeKey,
      themeRevision: themeRevision,
      language: language,
      code: code
    )
    if isComplete, let cached = resultCache[cacheKey] {
      touchResult(cacheKey)
      if let sessionID { sessions.removeValue(forKey: sessionID) }
      return cached
    }

    let previous = sessionID.flatMap { sessions[$0]?.document }
    let document = NativeSyntaxLexer.lex(code, as: language, reusing: previous)

    if let sessionID {
      if isComplete {
        sessions.removeValue(forKey: sessionID)
      } else {
        sessionRevision &+= 1
        sessions[sessionID] = SessionEntry(document: document, revision: sessionRevision)
        trimSessionsIfNeeded()
      }
    }

    let result = document.lines.map { line in
      var tokens: [Token] = []
      for lexeme in line.lexemes {
        let color = theme.foreground(for: lexeme.capture, language: language)
        if let last = tokens.last, last.color == color {
          tokens[tokens.count - 1] = Token(
            content: last.content + lexeme.content,
            color: color
          )
        } else {
          tokens.append(Token(content: lexeme.content, color: color))
        }
      }
      return tokens
    }

    if isComplete {
      resultCache[cacheKey] = result
      touchResult(cacheKey)
      if resultCacheOrder.count > resultCacheLimit {
        resultCache.removeValue(forKey: resultCacheOrder.removeFirst())
      }
    }
    return result
  }

  private func theme(for key: String, json: String) -> (NativeSyntaxTheme, UInt64)? {
    if let entry = themes[key], entry.json == json {
      guard let theme = entry.theme else { return nil }
      return (theme, entry.revision)
    }
    do {
      let theme = try NativeSyntaxTheme(json: json)
      themeRevision &+= 1
      themes[key] = ThemeEntry(json: json, theme: theme, revision: themeRevision)
      return (theme, themeRevision)
    } catch {
      log.error(
        "Failed to decode syntax theme \(key, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      themes[key] = ThemeEntry(json: json, theme: nil, revision: 0)
      return nil
    }
  }

  private func touchResult(_ key: ResultCacheKey) {
    if let index = resultCacheOrder.firstIndex(of: key) {
      resultCacheOrder.remove(at: index)
    }
    resultCacheOrder.append(key)
  }

  private func trimSessionsIfNeeded() {
    guard sessions.count > sessionLimit else { return }
    let overflow = sessions.count - sessionLimit
    let oldest = sessions.sorted { $0.value.revision < $1.value.revision }.prefix(overflow)
    for (key, _) in oldest { sessions.removeValue(forKey: key) }
  }
}
