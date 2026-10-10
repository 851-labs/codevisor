import Foundation

/// Finds inline code spans between already classified block-code ranges.
enum MarkdownInlineCodeRanges {
  static func ranges(in markdown: NSString, excluding blockRanges: [NSRange]) -> [NSRange] {
    var result: [NSRange] = []
    var cursor = 0
    for blockRange in blockRanges {
      if cursor < blockRange.location {
        scan(NSRange(location: cursor, length: blockRange.location - cursor), in: markdown, into: &result)
      }
      cursor = NSMaxRange(blockRange)
    }
    if cursor < markdown.length {
      scan(NSRange(location: cursor, length: markdown.length - cursor), in: markdown, into: &result)
    }
    return result
  }

  static func characterIsEscaped(at location: Int, in markdown: NSString) -> Bool {
    var slashCount = 0
    var index = location - 1
    while index >= 0, markdown.character(at: index) == 92 {
      slashCount += 1
      index -= 1
    }
    return slashCount.isMultiple(of: 2) == false
  }

  private static func scan(_ range: NSRange, in markdown: NSString, into result: inout [NSRange]) {
    let end = NSMaxRange(range)
    var cursor = range.location
    while let opening = consumeOpeningRun(in: markdown, cursor: &cursor, before: end) {
      let delimiterLength = cursor - opening
      if let closingEnd = matchingClosingEnd(
        after: cursor, delimiterLength: delimiterLength, in: markdown, before: end)
      {
        result.append(NSRange(location: opening, length: closingEnd - opening))
        cursor = closingEnd
      }
    }
  }

  private static func consumeOpeningRun(in markdown: NSString, cursor: inout Int, before end: Int) -> Int? {
    while cursor < end {
      guard markdown.character(at: cursor) == 96,
        !characterIsEscaped(at: cursor, in: markdown)
      else {
        cursor += 1
        continue
      }
      let opening = cursor
      while cursor < end, markdown.character(at: cursor) == 96 { cursor += 1 }
      return opening
    }
    return nil
  }

  private static func matchingClosingEnd(
    after cursor: Int, delimiterLength: Int, in markdown: NSString, before end: Int
  ) -> Int? {
    var search = cursor
    while search < end {
      guard markdown.character(at: search) == 96,
        !characterIsEscaped(at: search, in: markdown)
      else {
        search += 1
        continue
      }
      let closing = search
      while search < end, markdown.character(at: search) == 96 { search += 1 }
      if search - closing == delimiterLength { return search }
    }
    return nil
  }
}
