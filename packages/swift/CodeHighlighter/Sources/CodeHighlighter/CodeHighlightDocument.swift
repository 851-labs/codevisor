import Foundation

/// A document-scoped actor owns all mutable C objects. Edits are processed in
/// order; callers acknowledge only revisions actually applied to their view.
public actor CodeHighlightDocument {
  public struct Edit: Sendable {
    public let range: NSRange
    public let text: String
    public init(range: NSRange, text: String) { self.range = range; self.text = text }
  }

  public struct Style: Equatable, Sendable {
    public let foreground: String?
    public let bold: Bool
    public let italic: Bool
    public init(foreground: String? = nil, bold: Bool = false, italic: Bool = false) {
      self.foreground = foreground; self.bold = bold; self.italic = italic
    }
  }

  public struct Span: Equatable, Sendable {
    public let range: NSRange
    public let style: Style
  }

  public struct Update: Sendable {
    public let revision: Int
    /// Reset syntax attributes in this range before applying spans, including
    /// formerly highlighted text that no longer matches any query.
    public let invalidatedRange: NSRange
    public let spans: [Span]
  }

  private let language: String
  private var document: TreeSitterDocument?
  private var invalidated: NSRange?
  private var currentRevision = -1
  private var themeJSON: String?
  private var theme: NativeSyntaxTheme?
  private var styles: [String: Style] = [:]
  private var needsParse = false

  public init(language: String) { self.language = language }

  public func update(
    source: String, edits: [Edit]? = nil, themeJSON: String, revision: Int, forceFullHighlight: Bool = false
  ) throws -> Update {
    if document == nil {
      document = try TreeSitterDocument(source: source, language: language)
      invalidated = NSRange(location: 0, length: document!.text.count)
      needsParse = true
    } else if let document {
      let changes = edits ?? document.text.difference(from: source).map { [$0] } ?? []
      for edit in changes {
        invalidated = invalidated?.translated(by: edit)
        let affected = try document.apply(edit)
        invalidated = invalidated.map { NSUnionRange($0, affected) } ?? affected
        needsParse = true
      }
    }
    guard let document else { throw TreeSitterError.parse }
    if needsParse {
      if let changed = try document.parse() {
        invalidated = invalidated.map { NSUnionRange($0, changed) } ?? changed
      }
      needsParse = false
      if let range = invalidated {
        invalidated = NSUnionRange(range, document.enclosingRange(range))
      }
    }
    if self.themeJSON != themeJSON {
      theme = try NativeSyntaxTheme(json: themeJSON)
      self.themeJSON = themeJSON
      styles.removeAll()
      invalidated = NSRange(location: 0, length: document.text.count)
    }
    currentRevision = revision
    let fullRange = NSRange(location: 0, length: document.text.count)
    // Replacing native text storage discards attributes outside the text diff.
    // Repaint them while retaining the incremental parser and its syntax tree.
    if forceFullHighlight { invalidated = fullRange }
    let range = invalidated.map { NSIntersectionRange($0, fullRange) } ?? NSRange(location: 0, length: 0)
    let syntax = range.length > 0 ? try document.spans(in: range) : []
    let spans = resolve(syntax, in: range)
    return Update(revision: revision, invalidatedRange: range, spans: spans)
  }

  public func acknowledge(revision: Int) {
    if revision == currentRevision { invalidated = nil }
  }

  /// Completed code blocks need a snapshot, even if the streaming caller already
  /// acknowledged an earlier partial update.
  func snapshot(source: String, themeJSON: String, revision: Int) throws -> [Span] {
    invalidated = NSRange(location: 0, length: max(document?.text.count ?? 0, source.utf16.count))
    return try update(source: source, themeJSON: themeJSON, revision: revision).spans
  }

  var parseCount: Int { document?.parseCount ?? 0 }

  private func style(for span: SyntaxSpan) -> Style {
    let key = "\(span.language):\(span.capture)"
    if let cached = styles[key] { return cached }
    let language = SyntaxLanguage.resolve(span.language) ?? .markdown
    let result = theme?.style(for: span.capture, language: language) ?? Style()
    styles[key] = result
    return result
  }

  private func resolve(_ syntax: [SyntaxSpan], in range: NSRange) -> [Span] {
    struct Event { let offset: Int; let index: Int; let start: Bool }
    var events: [Event] = []
    for (index, span) in syntax.enumerated() {
      let clipped = NSIntersectionRange(range, span.range)
      if clipped.length > 0 {
        events.append(Event(offset: clipped.location, index: index, start: true))
        events.append(Event(offset: NSMaxRange(clipped), index: index, start: false))
      }
    }
    events.sort { $0.offset < $1.offset }
    var active = Set<Int>()
    var result: [Span] = []
    var previous = range.location
    for event in events {
      if event.offset > previous,
        let winner = active.max(by: { left, right in
          if syntax[left].priority != syntax[right].priority { return syntax[left].priority < syntax[right].priority }
          if syntax[left].range.length != syntax[right].range.length {
            return syntax[left].range.length > syntax[right].range.length
          }
          let leftSpecificity = syntax[left].capture.split(separator: ".").count
          let rightSpecificity = syntax[right].capture.split(separator: ".").count
          if leftSpecificity != rightSpecificity { return leftSpecificity < rightSpecificity }
          if syntax[left].order != syntax[right].order { return syntax[left].order < syntax[right].order }
          return left < right
        })
      {
        let resolved = style(for: syntax[winner])
        if let last = result.last, last.style == resolved, NSMaxRange(last.range) == previous {
          result[result.count - 1] = Span(
            range: NSRange(location: last.range.location, length: event.offset - last.range.location), style: resolved)
        } else {
          result.append(Span(range: NSRange(location: previous, length: event.offset - previous), style: resolved))
        }
      }
      if event.start { active.insert(event.index) } else { active.remove(event.index) }
      previous = event.offset
    }
    return result
  }
}
