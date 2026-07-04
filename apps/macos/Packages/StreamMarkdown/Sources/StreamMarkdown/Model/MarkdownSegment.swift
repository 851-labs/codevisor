import Foundation

/// A renderable segment of a markdown document: either a run of consecutive
/// text-like blocks that can merge into a single selectable `Text`, or a
/// standalone block that needs its own view (code, table, quote, rule).
///
/// Merging consecutive text blocks into one run is what makes multi-line /
/// multi-block text selection work: SwiftUI's `.textSelection(.enabled)` is
/// scoped per `Text` view, so selection can never cross the boundary between
/// two separate `Text`s. One run → one `Text` → continuous selection.
public enum MarkdownSegment: Sendable, Equatable {
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

        func flush() {
            guard !run.isEmpty else { return }
            result.append(.textRun(run))
            run = []
        }

        for block in blocks {
            if isTextRunBlock(block) {
                run.append(block)
            } else {
                flush()
                result.append(.block(block))
            }
        }
        flush()
        return result
    }
}
