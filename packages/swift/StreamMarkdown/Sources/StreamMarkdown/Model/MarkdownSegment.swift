import Foundation

public enum MarkdownSegment: Sendable, Equatable {
  case textRun([MarkdownBlock])
  case block(MarkdownBlock)

  private static func isTextRunBlock(_ block: MarkdownBlock) -> Bool {
    switch block {
    case .heading, .paragraph, .bulletList, .orderedList:
      return true
    case .codeBlock, .list, .blockQuote, .table, .thematicBreak:
      return false
    }
  }

  public static func segments(from blocks: [MarkdownBlock]) -> [MarkdownSegment] {
    blocks.map { block in
      isTextRunBlock(block) ? .textRun([block]) : .block(block)
    }
  }
  var blocks: [MarkdownBlock] {
    switch self {
    case let .textRun(blocks): blocks
    case let .block(block): [block]
    }
  }
}

struct MarkdownRenderSegment: Identifiable, Sendable, Equatable {
  let id: UInt64
  let segment: MarkdownSegment

  static func initial(_ segments: [MarkdownSegment]) -> [MarkdownRenderSegment] {
    segments.enumerated().map { index, segment in
      MarkdownRenderSegment(id: UInt64(index), segment: segment)
    }
  }
}
