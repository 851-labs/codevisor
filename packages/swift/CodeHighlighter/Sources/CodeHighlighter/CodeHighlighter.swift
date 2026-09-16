import Foundation
import os

private let log = Logger(subsystem: "com.851labs.codevisor", category: "highlighting")

/// Snapshot adapter for chat and diffs over our document-scoped Tree-sitter
/// engine. Native editors use CodeHighlightDocument's range updates directly.
public actor CodeHighlighter {
  public struct Token: Sendable, Equatable, Codable {
    public let content: String
    public let color: String?
    public let bold: Bool
    public let italic: Bool

    public init(content: String, color: String?, bold: Bool = false, italic: Bool = false) {
      self.content = content
      self.color = color
      self.bold = bold
      self.italic = italic
    }
  }

  private struct CacheKey: Hashable {
    let language: SyntaxLanguage
    let themeRevision: UInt64
    let source: String
  }
  private struct Session {
    let document: CodeHighlightDocument
    let language: SyntaxLanguage
    let revision: UInt64
  }
  public static let shared = CodeHighlighter()
  private var cache: [CacheKey: [[Token]]] = [:]
  private var cacheOrder: [CacheKey] = []
  private var cachedBytes = 0
  private var themes: [String: (json: String, revision: UInt64)] = [:]
  private var sessions: [String: Session] = [:]
  private var revision: UInt64 = 0

  public init() {}

  public static func language(forPath path: String) -> String? {
    let name = (path as NSString).lastPathComponent
    if [".bashrc", ".zshrc", ".bash_profile"].contains(name) { return "bash" }
    return extensionLanguages[(path as NSString).pathExtension.lowercased()]?.rawValue
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

  public func highlight(
    code: String, language: String?, themeKey: String, themeJSON: String,
    sessionID: String? = nil, isComplete: Bool = true
  ) async -> [[Token]]? {
    guard let language = SyntaxLanguage.resolve(language) else { return nil }
    revision &+= 1
    let requestRevision = revision
    if themes[themeKey]?.json != themeJSON {
      if themes.count >= 64 { themes.removeAll() }
      themes[themeKey] = (themeJSON, revision)
    }
    let key = CacheKey(language: language, themeRevision: themes[themeKey]!.revision, source: code)
    if isComplete, let cached = cache[key] {
      if let sessionID { sessions.removeValue(forKey: sessionID) }
      return cached
    }
    let existing = sessionID.flatMap { sessions[$0] }
    let document =
      existing?.language == language ? existing!.document : CodeHighlightDocument(language: language.rawValue)
    if let sessionID {
      if isComplete {
        sessions.removeValue(forKey: sessionID)
      } else {
        sessions[sessionID] = Session(document: document, language: language, revision: revision)
        if sessions.count > 32, let oldest = sessions.min(by: { $0.value.revision < $1.value.revision }) {
          sessions.removeValue(forKey: oldest.key)
        }
      }
    }
    do {
      let spans = try await document.snapshot(source: code, themeJSON: themeJSON, revision: Int(requestRevision))
      let result = Self.tokens(code: code, spans: spans)
      let cost = code.utf8.count * 4 + result.reduce(0) { $0 + $1.count * 64 }
      if isComplete, !Task.isCancelled, cost <= 8 * 1024 * 1024, cache[key] == nil {
        cache[key] = result
        cacheOrder.append(key)
        cachedBytes += cost
        while cachedBytes > 16 * 1024 * 1024 || cacheOrder.count > 200 {
          let oldest = cacheOrder.removeFirst()
          if let removed = cache.removeValue(forKey: oldest) {
            cachedBytes -= oldest.source.utf8.count * 4 + removed.reduce(0) { $0 + $1.count * 64 }
          }
        }
      }
      return result
    } catch {
      if !(error is CancellationError), !Task.isCancelled {
        log.error("Tree-sitter highlighting failed: \(String(describing: error), privacy: .public)")
      }
      return nil
    }
  }

  public func releaseSession(_ id: String) { sessions.removeValue(forKey: id) }

  private static func tokens(code: String, spans: [CodeHighlightDocument.Span]) -> [[Token]] {
    let source = code as NSString
    var lines: [[Token]] = [[]]
    func append(_ range: NSRange, _ style: CodeHighlightDocument.Style) {
      guard range.length > 0 else { return }
      for (index, part) in source.substring(with: range).components(separatedBy: "\n").enumerated() {
        if index > 0 { lines.append([]) }
        guard !part.isEmpty else { continue }
        let line = lines.count - 1
        if let last = lines[line].last, last.color == style.foreground, last.bold == style.bold,
          last.italic == style.italic
        {
          lines[line][lines[line].count - 1] = Token(
            content: last.content + part, color: style.foreground, bold: style.bold, italic: style.italic)
        } else {
          lines[line].append(Token(content: part, color: style.foreground, bold: style.bold, italic: style.italic))
        }
      }
    }
    var offset = 0
    for span in spans {
      if span.range.location > offset {
        append(NSRange(location: offset, length: span.range.location - offset), .init())
      }
      append(span.range, span.style)
      offset = NSMaxRange(span.range)
    }
    if offset < source.length { append(NSRange(location: offset, length: source.length - offset), .init()) }
    return lines
  }
}
