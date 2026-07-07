import SwiftUI

/// Renders markdown text, re-parsing on change so streamed responses display
/// incrementally. Blocks render in document order, including tool output and
/// partially-arrived code fences.
public struct StreamingMarkdownView: View {
    private let text: String
    /// Per-view-identity memo of the last parse. `body` runs far more often
    /// than the text changes (theme changes, sibling observable churn, the
    /// per-frame re-renders of a streaming transcript), and parsing an
    /// entire long message on the main thread each time was a dominant
    /// source of streaming jank.
    @State private var cache = SegmentCache()

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        MarkdownSegmentListView(segments: cache.segments(for: text))
    }
}

/// Memoizes block parsing + segment grouping for the last-seen text. A plain
/// class held in `@State`: it must persist across body evaluations without
/// being observable (cache writes must not re-render the view).
///
/// Misses fall through to the process-level `MarkdownSegmentCache`: LazyVStack
/// destroys this per-view cache whenever a row scrolls out of the viewport
/// buffer, and without the shared layer every row re-entering during a scroll
/// re-parsed its entire message on the main thread — the dominant source of
/// scroll lag on long transcripts.
@MainActor
private final class SegmentCache {
    private var lastText: String?
    private var lastSegments: [MarkdownSegment] = []

    func segments(for text: String) -> [MarkdownSegment] {
        if text == lastText { return lastSegments }

        // A growing text (the previous text is a strict prefix) is a
        // streaming flush. Parse directly instead of via the shared LRU:
        // each intermediate text can never be requested again, and storing
        // ~60 of them per second evicted the settled messages the cache
        // exists for.
        let isStreamingGrowth = lastText.map { !$0.isEmpty && text.hasPrefix($0) } ?? false
        var segments = isStreamingGrowth
            ? MarkdownSegmentCache.shared.parse(text)
            : MarkdownSegmentCache.shared.segments(for: text)

        // Re-use the previous parse's instances for segments whose content is
        // unchanged. A fresh parse allocates new String storage for every
        // block, and SwiftUI's change detection compares stored properties
        // structurally (String storage pointers, not contents) — so without
        // this, EVERY segment of a streaming message read as "changed" on
        // every ~16ms flush and the entire message re-rendered (AttributedString
        // rebuild + CoreText layout + display list) 60× per second. With
        // pointer-stable prefixes, only the segment actually receiving text
        // re-renders.
        let shared = min(segments.count, lastSegments.count)
        var index = 0
        while index < shared, segments[index] == lastSegments[index] {
            segments[index] = lastSegments[index]
            index += 1
        }

        lastText = text
        lastSegments = segments
        return segments
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
                switch segment {
                case let .textRun(runBlocks):
                    MarkdownTextRunView(blocks: runBlocks)
                case let .block(block):
                    MarkdownBlockView(block: block)
                }
            }
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
