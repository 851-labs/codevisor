import Foundation

struct MarkdownParseResult {
  let blocks: [MarkdownBlock]
  var reusableBlockCount = 0
  var reparseStart = 0
  var tableByteRanges: [Range<Int>] = []
}

public struct IncrementalMarkdownParser: Sendable {
  private var source = ""
  private var blocks: [MarkdownBlock] = []
  private var reusableBlockCount = 0
  private var reparseStart = 0
  private var containsReferenceDefinition = false
  public private(set) var parsedByteCount = 0

  public init() {}

  public mutating func parse(_ source: String) -> [MarkdownBlock] {
    guard source != self.source else {
      parsedByteCount = 0
      return blocks
    }
    let appending = source.utf8.starts(with: self.source.utf8)
    let changedLines = appending ? Self.lineStart(before: self.source.utf8.count, in: source) : 0
    containsReferenceDefinition =
      (appending && containsReferenceDefinition)
      || Self.containsDefinitionMarker(source.utf8.dropFirst(changedLines))
    let start = appending && !containsReferenceDefinition ? reparseStart : 0
    let prefixCount = start > 0 ? reusableBlockCount : 0
    let tail = String(decoding: source.utf8.dropFirst(start), as: UTF8.self)
    let parsed = MarkdownParser().parseDocument(tail)
    parsedByteCount = tail.utf8.count
    blocks = Array(blocks.prefix(prefixCount)) + parsed.blocks
    reusableBlockCount = prefixCount + parsed.reusableBlockCount
    reparseStart = start + parsed.reparseStart
    self.source = source
    return blocks
  }

  private static let newline = UInt8(ascii: "\n")
  private static let closingBracket = UInt8(ascii: "]")
  private static let colon = UInt8(ascii: ":")

  private static func lineStart(before offset: Int, in source: String) -> Int {
    let prefix = source.utf8.prefix(offset)
    guard let newline = prefix.lastIndex(of: newline) else { return 0 }
    return prefix.distance(from: prefix.startIndex, to: newline) + 1
  }

  private static func containsDefinitionMarker(_ bytes: Substring.UTF8View) -> Bool {
    zip(bytes, bytes.dropFirst()).contains { $0 == closingBracket && $1 == colon }
  }
}
