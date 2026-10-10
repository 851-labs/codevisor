import CMD4C
import Foundation

/// Parses CommonMark plus the MD4C GitHub extensions into Codevisor's semantic
/// render model. MD4C is the only component that decides block and span
/// structure; this type only copies callback data into memory-safe Swift values.
public struct MarkdownParser: Sendable {
  public init() {}

  public func parse(_ markdown: String) -> [MarkdownBlock] {
    parseDocument(markdown).blocks
  }

  /// Table boundaries come from MD4C, including headers and empty cells.
  /// The UTF-16 ranges can be used with Foundation's Markdown link matches.
  public func parseWithTableRanges(_ markdown: String) -> (blocks: [MarkdownBlock], tableRanges: [NSRange]) {
    let result = parseDocument(markdown)
    let utf8 = markdown.utf8
    let ranges = result.tableByteRanges.map { range in
      let start = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
      let end = utf8.index(utf8.startIndex, offsetBy: range.upperBound)
      return NSRange(start..<end, in: markdown)
    }
    return (result.blocks, ranges)
  }

  func parseDocument(_ markdown: String) -> MarkdownParseResult {
    guard !markdown.isEmpty else { return MarkdownParseResult(blocks: []) }
    guard markdown.utf8.count <= Int(UInt32.max) else {
      return MarkdownParseResult(blocks: [.paragraph(MarkdownText(markdown))])
    }

    let context = MD4CParserContext(
      fenceCompletions: FenceCompletionDetector.completions(in: markdown)
    )
    var input = markdown
    let result: Int32 = input.withUTF8 { bytes in
      guard let baseAddress = bytes.baseAddress else { return 0 }
      context.sourceBytes = bytes
      defer { context.sourceBytes = nil }
      var parser = MD_PARSER()
      parser.abi_version = 0
      parser.flags =
        UInt32(MD_FLAG_PERMISSIVEURLAUTOLINKS)
        | UInt32(MD_FLAG_PERMISSIVEEMAILAUTOLINKS)
        | UInt32(MD_FLAG_PERMISSIVEWWWAUTOLINKS)
        | UInt32(MD_FLAG_TABLES)
        | UInt32(MD_FLAG_STRIKETHROUGH)
        | UInt32(MD_FLAG_TASKLISTS)
        | UInt32(MD_FLAG_NOHTMLBLOCKS)
        | UInt32(MD_FLAG_NOHTMLSPANS)
      parser.enter_block = MD4CParserContext.enterBlockCallback
      parser.leave_block = MD4CParserContext.leaveBlockCallback
      parser.enter_span = MD4CParserContext.enterSpanCallback
      parser.leave_span = MD4CParserContext.leaveSpanCallback
      parser.text = MD4CParserContext.textCallback
      parser.debug_log = nil
      parser.syntax = nil

      return md_parse(
        UnsafeRawPointer(baseAddress).assumingMemoryBound(to: MD_CHAR.self),
        MD_SIZE(bytes.count),
        &parser,
        Unmanaged.passUnretained(context).toOpaque()
      )
    }

    guard result == 0 else {
      return MarkdownParseResult(
        blocks: markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? [] : [.paragraph(MarkdownText(markdown))]
      )
    }
    return MarkdownParseResult(
      blocks: context.blocks,
      reusableBlockCount: context.reusableBlockCount,
      reparseStart: context.reparseStart,
      tableByteRanges: context.tableByteRanges
    )
  }

  /// Parses an inline fragment with the same MD4C configuration used for
  /// complete documents. Production rendering normally receives spans from
  /// the original document parse; this is retained for public callers and
  /// isolated renderer tests.
  public func parseInline(_ markdown: String) -> MarkdownText {
    let blocks = parse(markdown)
    if blocks.count == 1 {
      switch blocks[0] {
      case let .paragraph(text), let .heading(_, text): return text
      default: break
      }
    }
    return MarkdownText(markdown)
  }
}
