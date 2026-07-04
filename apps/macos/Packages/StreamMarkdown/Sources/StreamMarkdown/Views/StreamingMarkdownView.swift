import SwiftUI

/// Renders markdown text, re-parsing on change so streamed responses display
/// incrementally. Blocks render in document order, including tool output and
/// partially-arrived code fences.
public struct StreamingMarkdownView: View {
    private let text: String
    private let parser = MarkdownParser()

    @Environment(\.markdownTheme) private var theme

    public init(_ text: String) {
        self.text = text
    }

    private var blocks: [MarkdownBlock] {
        parser.parse(text)
    }

    public var body: some View {
        MarkdownSegmentsView(blocks: blocks)
    }
}

/// Renders markdown blocks as segments: consecutive text-like blocks merge
/// into a single selectable `Text` (so selection can span multiple lines and
/// blocks — SwiftUI text selection cannot cross `Text` boundaries), while
/// code blocks, tables, quotes, and rules keep their own views.
struct MarkdownSegmentsView: View {
    let blocks: [MarkdownBlock]
    @Environment(\.markdownTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.blockSpacing) {
            ForEach(Array(MarkdownSegment.segments(from: blocks).enumerated()), id: \.offset) { _, segment in
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
