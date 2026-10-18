import Foundation

public enum ColumnAlignment: Sendable, Equatable, Hashable {
  case leading
  case center
  case trailing
  case none
}

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

  public var imageSources: [String] { spans.flatMap(\.imageSources) }
}

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

  public var imageSources: [String] {
    switch self {
    case let .image(_, source, _): [source]
    case let .emphasis(children), let .strong(children), let .strikethrough(children),
      let .link(children, _, _):
      children.flatMap(\.imageSources)
    default: []
    }
  }
}

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

  public static func bullet(depth: Int) -> String {
    switch depth {
    case 0: "•"
    case 1: "◦"
    default: "▪"
    }
  }

  public static func isBullet(_ marker: String) -> Bool {
    marker == "•" || marker == "◦" || marker == "▪"
  }

  public func marker(for item: MarkdownListItem, at index: Int, depth: Int = 0) -> String {
    if item.isTask { return item.isChecked ? "☑" : "☐" }
    return isOrdered ? "\(start + index)\(delimiter)" : Self.bullet(depth: depth)
  }
}

public indirect enum MarkdownBlock: Sendable, Equatable, Hashable, Identifiable {
  case heading(level: Int, text: MarkdownText)
  case paragraph(MarkdownText)
  case codeBlock(language: String?, code: String, isComplete: Bool)
  case bulletList([MarkdownText])
  case orderedList([OrderedListItem])
  case list(MarkdownList)
  case blockQuote([MarkdownBlock])
  case table(headers: [MarkdownText], alignments: [ColumnAlignment], rows: [[MarkdownText]])
  case thematicBreak

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

  public var imageSources: [String] {
    switch self {
    case let .heading(_, text), let .paragraph(text): text.imageSources
    case let .bulletList(items): items.flatMap(\.imageSources)
    case let .orderedList(items): items.flatMap { $0.text.imageSources }
    case let .list(list): list.items.flatMap { $0.blocks.flatMap(\.imageSources) }
    case let .blockQuote(blocks): blocks.flatMap(\.imageSources)
    case let .table(headers, _, rows): (headers + rows.flatMap { $0 }).flatMap(\.imageSources)
    case .codeBlock, .thematicBreak: []
    }
  }
}
