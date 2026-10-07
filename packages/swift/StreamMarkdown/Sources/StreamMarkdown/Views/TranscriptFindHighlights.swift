import Foundation

/// Find-in-chat matches inside one transcript text surface, painted beneath
/// the glyphs the way a browser's find bar marks a page.
public struct TranscriptFindHighlights: Equatable, Sendable {
  /// UTF-16 ranges of every match in the surface, in text order.
  public var ranges: [NSRange]
  /// Index into `ranges` of the match the find bar is on, when that match is
  /// in this surface.
  public var currentIndex: Int?

  public init(ranges: [NSRange], currentIndex: Int? = nil) {
    self.ranges = ranges
    self.currentIndex = currentIndex
  }

  public var currentRange: NSRange? {
    currentIndex.flatMap { ranges.indices.contains($0) ? ranges[$0] : nil }
  }
}

public enum TranscriptFindText {
  private static let options: NSString.CompareOptions = [
    .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
  ]

  /// Non-overlapping occurrences of `query` in `text`, ignoring case,
  /// diacritics, and character width, as browsers do.
  public static func ranges(of query: String, in text: String) -> [NSRange] {
    var ranges: [NSRange] = []
    forEachMatch(of: query, in: text) { ranges.append($0) }
    return ranges
  }

  /// The number of matches `ranges(of:in:)` would return, without
  /// materializing them: a one-letter query can match hundreds of
  /// thousands of times in a long transcript.
  public static func count(of query: String, in text: String) -> Int {
    var count = 0
    forEachMatch(of: query, in: text) { _ in count += 1 }
    return count
  }

  private static func forEachMatch(of query: String, in text: String, _ body: (NSRange) -> Void) {
    guard !query.isEmpty else { return }
    let haystack = text as NSString
    var searchRange = NSRange(location: 0, length: haystack.length)
    while searchRange.length > 0 {
      let found = haystack.range(of: query, options: options, range: searchRange)
      guard found.location != NSNotFound, found.length > 0 else { break }
      body(found)
      let next = NSMaxRange(found)
      searchRange = NSRange(location: next, length: haystack.length - next)
    }
  }
}

#if canImport(AppKit) || canImport(UIKit)
  import SwiftUI

  extension TranscriptFindText {
    /// The text of each selectable surface a settled Markdown row presents,
    /// in order. A run of prose shares one surface; anything else gets one
    /// surface per block, and separators get none.
    ///
    /// Not main-actor isolated: find builds these for a whole transcript on
    /// a background index, the same way prepared text layout renders runs on
    /// a worker. It bypasses the main-actor render cache for that reason.
    public static func surfaceTexts(blocks: [MarkdownBlock], theme: MarkdownTheme) -> [String] {
      if blocks.allSatisfy(\.isTextRunCompatible) {
        return [textRun(blocks, theme: theme)]
      }
      return blocks.compactMap { block in
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList, .blockQuote, .list:
          return textRun([block], theme: theme)
        case let .codeBlock(_, code, _):
          return code
        case let .table(headers, _, rows):
          return ([headers] + rows)
            .map { $0.map(\.plainText).joined(separator: "\t") }
            .joined(separator: "\n")
        case .thematicBreak:
          return nil
        }
      }
    }

    private static func textRun(_ blocks: [MarkdownBlock], theme: MarkdownTheme) -> String {
      MarkdownTextRunRenderer.attributedString(
        for: blocks,
        theme: theme,
        foregroundColor: theme.textForeground
      ).string
    }
  }
#endif
