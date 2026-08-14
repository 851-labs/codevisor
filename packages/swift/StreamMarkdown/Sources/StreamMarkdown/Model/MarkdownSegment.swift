import Foundation

/// A renderable segment of a markdown document: either a run of consecutive
/// text-like blocks that can merge into one selectable TextKit storage, or a
/// standalone block that needs its own view (code, table, quote, rule).
///
/// Merging consecutive text blocks into one native storage is what makes
/// multi-line / multi-block text selection continuous.
public enum MarkdownSegment: Sendable, Equatable {
    /// One enormous selectable text storage makes TextKit reflow the whole
    /// document as it enters/leaves a lazy stack or the chat width changes.
    /// Chunk at markdown block boundaries so long answers remain cheap to
    /// mount and scroll. Normal responses still stay a single selectable run.
    static let maximumTextRunCharacters = 4_096
    case textRun([MarkdownBlock])
    case block(MarkdownBlock)

    /// Whether a block can be rendered as part of a merged text run.
    public static func isTextRunBlock(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList:
            return true
        case .codeBlock, .blockQuote, .table, .thematicBreak:
            return false
        }
    }

    /// Groups blocks into segments, coalescing consecutive text-like blocks
    /// into a single `.textRun`.
    public static func segments(from blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        var result: [MarkdownSegment] = []
        var run: [MarkdownBlock] = []
        var runCharacters = 0

        func flush() {
            guard !run.isEmpty else { return }
            result.append(.textRun(run))
            run = []
            runCharacters = 0
        }

        for block in blocks {
            if isTextRunBlock(block) {
                let characters = textLength(of: block)
                if !run.isEmpty, runCharacters + characters > maximumTextRunCharacters {
                    flush()
                }
                run.append(block)
                runCharacters += characters
            } else {
                flush()
                result.append(.block(block))
            }
        }
        flush()
        return result
    }

    private static func textLength(of block: MarkdownBlock) -> Int {
        switch block {
        case let .heading(_, text), let .paragraph(text):
            return text.count
        case let .bulletList(items):
            return items.reduce(0) { $0 + $1.count }
        case let .orderedList(items):
            return items.reduce(0) { $0 + $1.text.count }
        case .codeBlock, .blockQuote, .table, .thematicBreak:
            return 0
        }
    }
}
