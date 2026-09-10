import Foundation

struct MarkdownParseResult {
  let blocks: [MarkdownBlock]
  var reusableBlockCount = 0
  var reparseStart = 0
}

/// Reuses complete top-level blocks while an append changes the document's
/// tail. MD4C supplies the boundary. Reference syntax disables reuse because
/// a later definition can change any earlier inline span. Edits fall back to
/// a complete parse; the result always has ordinary full-document semantics.
public struct IncrementalMarkdownParser: Sendable {
  private var source = ""
  private var blocks: [MarkdownBlock] = []
  private var reusableBlockCount = 0
  private var reparseStart = 0
  private var containsReferenceSyntax = false
  public private(set) var parsedByteCount = 0

  public init() {}

  public mutating func parse(_ source: String) -> [MarkdownBlock] {
    guard source != self.source else {
      parsedByteCount = 0
      return blocks
    }
    let appending = source.utf8.starts(with: self.source.utf8)
    let suffix = appending ? source.utf8.dropFirst(self.source.utf8.count) : source.utf8[...]
    containsReferenceSyntax = (appending && containsReferenceSyntax) || suffix.contains(91)
    let start = appending && !containsReferenceSyntax ? reparseStart : 0
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
}
