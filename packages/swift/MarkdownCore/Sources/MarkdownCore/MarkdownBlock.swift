import Foundation

/// Column alignment in a GFM table.
public enum ColumnAlignment: Sendable, Equatable, Hashable {
  case leading
  case center
  case trailing
  case none
}

/// Semantic inline Markdown produced by MD4C.
///
/// Keeping the resolved span tree with the block is important: reference-style
/// links can be defined later in the document, so reparsing each rendered block
/// independently would not be CommonMark-correct.
public struct MarkdownText: Sendable, Equatable, Hashable, ExpressibleByStringLiteral {
  public let spans: [MarkdownSpan]

  public init(spans: [MarkdownSpan]) {
    self.spans = spans
  }

  public init(_ text: String) {
    spans = text.isEmpty ? [] : [.text(text)]
  }

  public init(stringLiteral value: String) {
    self.init(value)
  }

  public var plainText: String {
    spans.map(\.plainText).joined()
  }

  public var characterCount: Int { plainText.count }
}

/// A resolved inline Markdown node. Text is materialized while parsing; this
/// deliberately favors simple ownership and safe reconciliation over retaining
/// unsafe pointers into MD4C's temporary input buffer.
public indirect enum MarkdownSpan: Sendable, Equatable, Hashable {
  case text(String)
  case emphasis([MarkdownSpan])
  case strong([MarkdownSpan])
  case strikethrough([MarkdownSpan])
  case code(String)
  case link(children: [MarkdownSpan], destination: String, title: String?)
  case image(alt: [MarkdownSpan], source: String, title: String?)
  case softBreak
  case hardBreak

  public var plainText: String {
    switch self {
    case let .text(text), let .code(text):
      text
    case let .emphasis(children), let .strong(children), let .strikethrough(children):
      children.map(\.plainText).joined()
    case let .link(children, _, _):
      children.map(\.plainText).joined()
    case let .image(alt, _, _):
      alt.map(\.plainText).joined()
    case .softBreak, .hardBreak:
      "\n"
    }
  }
}

/// An ordered-list item with its rendered number.
public struct OrderedListItem: Sendable, Equatable, Hashable {
  public let number: Int
  public let text: MarkdownText

  public init(number: Int, text: MarkdownText) {
    self.number = number
    self.text = text
  }

  public init(number: Int, text: String) {
    self.init(number: number, text: MarkdownParser().parseInline(text))
  }
}

/// A list item that can contain arbitrary nested block content.
public struct MarkdownListItem: Sendable, Equatable, Hashable {
  public let blocks: [MarkdownBlock]
  public let isTask: Bool
  public let isChecked: Bool

  public init(blocks: [MarkdownBlock], isTask: Bool = false, isChecked: Bool = false) {
    self.blocks = blocks
    self.isTask = isTask
    self.isChecked = isChecked
  }
}

/// A CommonMark list. Unlike the compatibility list cases, this form retains
/// nesting, loose-list blocks, task state, start number, and delimiter.
public struct MarkdownList: Sendable, Equatable, Hashable {
  public let isOrdered: Bool
  public let start: Int
  public let delimiter: Character
  public let isTight: Bool
  public let items: [MarkdownListItem]

  public init(
    isOrdered: Bool,
    start: Int = 1,
    delimiter: Character,
    isTight: Bool,
    items: [MarkdownListItem]
  ) {
    self.isOrdered = isOrdered
    self.start = start
    self.delimiter = delimiter
    self.isTight = isTight
    self.items = items
  }
}

/// A semantic Markdown block produced by MD4C.
public indirect enum MarkdownBlock: Sendable, Equatable, Hashable, Identifiable {
  case heading(level: Int, text: MarkdownText)
  case paragraph(MarkdownText)
  case codeBlock(language: String?, code: String, isComplete: Bool)
  /// Compatibility shape retained for simple tight lists.
  case bulletList([MarkdownText])
  /// Compatibility shape retained for simple tight ordered lists.
  case orderedList([OrderedListItem])
  /// Full recursive list representation used for nested, loose, and task lists.
  case list(MarkdownList)
  case blockQuote([MarkdownBlock])
  case table(headers: [MarkdownText], alignments: [ColumnAlignment], rows: [[MarkdownText]])
  case thematicBreak

  /// Convenience overloads keep callers with dynamically-created strings
  /// source-compatible with the pre-MD4C model.
  public static func heading(level: Int, text: String) -> MarkdownBlock {
    .heading(level: level, text: MarkdownParser().parseInline(text))
  }

  public static func paragraph(_ text: String) -> MarkdownBlock {
    .paragraph(MarkdownParser().parseInline(text))
  }

  public static func bulletList(_ items: [String]) -> MarkdownBlock {
    let parser = MarkdownParser()
    return .bulletList(items.map(parser.parseInline))
  }

  public var id: String {
    switch self {
    case let .heading(level, text): return "h\(level):\(text.plainText)"
    case let .paragraph(text): return "p:\(text.plainText)"
    case let .codeBlock(language, code, complete): return "code:\(language ?? ""):\(complete):\(code)"
    case let .bulletList(items): return "ul:\(items.map(\.plainText).joined(separator: "\u{1}"))"
    case let .orderedList(items):
      return "ol:\(items.map { "\($0.number).\($0.text.plainText)" }.joined(separator: "\u{1}"))"
    case let .list(list):
      return "list:\(list.isOrdered):\(list.start):\(list.items.count)"
    case let .blockQuote(blocks): return "quote:\(blocks.map(\.id).joined(separator: "\u{1}"))"
    case let .table(headers, _, rows):
      return "table:\(headers.map(\.plainText).joined(separator: "|")):\(rows.count)"
    case .thematicBreak: return "hr"
    }
  }
}
