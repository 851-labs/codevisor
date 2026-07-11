import SwiftUI

/// Renders markdown text, re-parsing on change so streamed responses display
/// incrementally. Blocks render in document order, including tool output and
/// partially-arrived code fences.
///
/// Pass `isComplete: false` while the text is still streaming: the segmenter
/// then re-parses only the unsettled tail per flush and renders each block as
/// its own segment, so per-flush work scales with the growing block instead
/// of the whole document. When the flag flips back to true the segments merge
/// into selectable runs again (one full re-render at finalize). The default
/// (`true`) is right for any text that arrives whole.
public struct StreamingMarkdownView: View {
    private let text: String
    private let isComplete: Bool
    /// Per-view-identity incremental state (see `StreamingSegmenter`). A
    /// plain non-observable class held in `@State`: `body` runs far more
    /// often than the text changes (theme changes, sibling observable churn,
    /// the per-frame re-renders of a streaming transcript), and it must
    /// persist across body evaluations without cache writes re-rendering the
    /// view. Fresh identities fall through to the process-level
    /// `MarkdownSegmentCache`.
    @State private var segmenter = StreamingSegmenter()

    public init(_ text: String, isComplete: Bool = true) {
        self.text = text
        self.isComplete = isComplete
    }

    public var body: some View {
        MarkdownSegmentListView(segments: segmenter.segments(for: text, isComplete: isComplete))
    }
}

/// Renders markdown blocks as segments: consecutive text-like blocks merge
/// into a single selectable `Text` (so selection can span multiple lines and
/// blocks — SwiftUI text selection cannot cross `Text` boundaries), while
/// code blocks, tables, quotes, and rules keep their own views.
struct MarkdownSegmentsView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        MarkdownSegmentListView(segments: MarkdownSegment.segments(from: blocks))
    }
}

/// Renders pre-computed markdown segments in document order.
struct MarkdownSegmentListView: View {
    let segments: [MarkdownSegment]
    @Environment(\.markdownTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.blockSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                MarkdownSegmentView(segment: segment)
                    .equatable()
            }
        }
    }
}

/// A settled streaming segment is an explicit SwiftUI equality boundary.
/// Growing the hosting surface still lays out the stack, but it cannot rebuild
/// or repaint the already-rendered prefix; only the changing tail crosses this
/// boundary. `StreamingSegmenter` preserves the values of settled segments,
/// making the comparison O(1) in the steady state.
private struct MarkdownSegmentView: View, Equatable {
    let segment: MarkdownSegment

    var body: some View {
        switch segment {
        case let .textRun(runBlocks):
            MarkdownTextRunView(blocks: runBlocks)
        case let .block(block):
            MarkdownBlockView(block: block)
        }
    }
}

/// Renders a single markdown block.
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    @Environment(\.markdownTheme) private var theme

    var body: some View {
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList:
            // Normally coalesced into a MarkdownTextRunView by
            // MarkdownSegmentsView; render standalone blocks the same way so
            // they stay selectable.
            MarkdownTextRunView(blocks: [block])

        case let .codeBlock(language, code, isComplete):
            CodeBlockView(language: language, code: code, isComplete: isComplete)

        case let .blockQuote(blocks):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(theme.quoteBarColor)
                    .frame(width: 3)
                MarkdownSegmentsView(blocks: blocks)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .table(headers, alignments, rows):
            MarkdownTableView(headers: headers, alignments: alignments, rows: rows)

        case .thematicBreak:
            Divider()
        }
    }
}

#Preview("Rich document") {
    ScrollView {
        StreamingMarkdownView("""
        # Heading One

        A paragraph with **bold**, *italic*, and `inline code`.

        - First bullet
        - Second bullet

        1. Step one
        2. Step two

        > A thoughtful quote.

        | Name | Role |
        | :--- | ---: |
        | Ann  | Lead |

        ```swift
        let greeting = "Hello"
        print(greeting)
        ```

        ---
        Done.
        """)
        .padding()
    }
    .frame(width: 460, height: 640)
}

#Preview("Streaming (incomplete fence)") {
    StreamingMarkdownView("""
    Here is some code being written:

    ```swift
    func work() {
        let value = 4
    """)
    .padding()
    .frame(width: 420)
}
