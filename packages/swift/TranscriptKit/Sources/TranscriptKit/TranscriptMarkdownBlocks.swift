import Foundation

enum TranscriptMarkdownBlocks {
  enum Kind {
    case paragraph
    case heading
    case list
    case quote
    case table
    case code(fence: String)
    case rule

    var canStandAlone: Bool {
      switch self {
      case .code, .table, .quote, .paragraph: true
      default: false
      }
    }

    var splitsParts: Bool {
      if case .rule = self { return true }
      return false
    }
  }

  struct Block {
    var kind: Kind
    var source: Range<String.Index>

    init(kind: Kind, line: Substring) {
      self.kind = kind
      source = line.startIndex..<line.endIndex
    }

    mutating func append(_ line: Substring) {
      source = source.lowerBound..<line.endIndex
    }
  }

  static func normalized(_ markdown: String) -> String {
    markdown.replacingOccurrences(of: "\r\n", with: "\n")
  }

  static func blocks(in markdown: String) -> [Block] {
    var blocks: [Block] = []
    var current: Block?
    var pendingBlank = false
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      if var block = current, case let .code(fence) = block.kind {
        block.append(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(fence), trimmed.allSatisfy({ $0 == fence.first }) {
          blocks.append(block)
          current = nil
        } else {
          current = block
        }
        continue
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        pendingBlank = current != nil
        continue
      }
      if var block = current, continues(block, with: line, afterBlank: pendingBlank) {
        block.append(line)
        current = block
      } else {
        if let block = current { blocks.append(block) }
        let kind = kind(of: line)
        current = Block(kind: kind, line: line)
        if case .heading = kind {
          blocks.append(current!)
          current = nil
        } else if case .rule = kind {
          blocks.append(current!)
          current = nil
        }
      }
      pendingBlank = false
    }
    if let current { blocks.append(current) }
    return blocks
  }

  private static func continues(_ block: Block, with line: Substring, afterBlank: Bool) -> Bool {
    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
    switch block.kind {
    case .list:
      if indent >= 2 { return true }
      if case .list = kind(of: line) { return true }
      return !afterBlank && startsParagraph(line)
    case .quote:
      guard !afterBlank else { return false }
      return line.drop(while: { $0 == " " }).hasPrefix(">") || startsParagraph(line)
    case .table:
      return !afterBlank && line.contains("|")
    case .paragraph:
      return !afterBlank && startsParagraph(line)
    case .heading, .code, .rule:
      return false
    }
  }

  private static func startsParagraph(_ line: Substring) -> Bool {
    if case .paragraph = kind(of: line) { return true }
    return false
  }

  private static func kind(of line: Substring) -> Kind {
    let indent = line.prefix { $0 == " " }.count
    guard indent < 4 else { return .paragraph }
    let trimmed = line.dropFirst(indent)
    if let fence = fence(opening: trimmed) { return .code(fence: fence) }
    if isRule(trimmed) { return .rule }
    if isHeading(trimmed) { return .heading }
    if trimmed.hasPrefix(">") { return .quote }
    if trimmed.hasPrefix("|") { return .table }
    if isListItem(trimmed) { return .list }
    return .paragraph
  }

  private static func fence(opening line: Substring) -> String? {
    for marker: Character in ["`", "~"] {
      let run = line.prefix { $0 == marker }.count
      if run >= 3 { return String(repeating: marker, count: run) }
    }
    return nil
  }

  private static func isRule(_ line: Substring) -> Bool {
    let compact = line.filter { $0 != " " }
    guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
    return compact.allSatisfy { $0 == first }
  }

  private static func isHeading(_ line: Substring) -> Bool {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return false }
    let rest = line.dropFirst(hashes)
    return rest.isEmpty || rest.first == " "
  }

  private static func isListItem(_ line: Substring) -> Bool {
    if let first = line.first, "-*+•".contains(first) {
      return line.dropFirst().first == " "
    }
    let digits = line.prefix(while: \.isNumber)
    guard (1...9).contains(digits.count) else { return false }
    let rest = line.dropFirst(digits.count)
    guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return false }
    return rest.dropFirst().first == " "
  }
}
