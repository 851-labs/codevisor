import Foundation

/// A renderable block of a Markdown document. Text-like blocks use TextKit;
/// structural blocks use their dedicated views.
///
/// Every parsed block deliberately remains its own segment. Streaming and
/// settled documents therefore have identical view topology and measurement,
/// and transcript virtualization can treat this boundary as a stable unit.
public enum MarkdownSegment: Sendable, Equatable {
    case textRun([MarkdownBlock])
    case block(MarkdownBlock)

    /// Whether a block can be rendered as part of a merged text run.
    public static func isTextRunBlock(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList:
            return true
        case .codeBlock, .list, .blockQuote, .table, .thematicBreak:
            return false
        }
    }

    /// Preserves one render segment per parsed block.
    public static func segments(from blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        blocks.map { block in
            isTextRunBlock(block) ? .textRun([block]) : .block(block)
        }
    }
}
