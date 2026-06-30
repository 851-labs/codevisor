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
        VStack(alignment: .leading, spacing: theme.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
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
        case let .heading(level, text):
            Text(InlineMarkdown.attributedString(from: text))
                .font(headingFont(for: level))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(text):
            Text(InlineMarkdown.attributedString(from: text))
                .font(theme.bodyFont)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case let .codeBlock(language, code, isComplete):
            CodeBlockView(language: language, code: code, isComplete: isComplete)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    MarkdownListRow(marker: "•", content: item)
                }
            }

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.number) { item in
                    MarkdownListRow(marker: "\(item.number).", content: item.text)
                }
            }

        case let .blockQuote(blocks):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(theme.quoteBarColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: theme.blockSpacing) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                        MarkdownBlockView(block: inner)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .table(headers, alignments, rows):
            MarkdownTableView(headers: headers, alignments: alignments, rows: rows)

        case .thematicBreak:
            Divider()
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        case 4: return .headline
        default: return .subheadline
        }
    }
}

/// A list row with a leading marker.
struct MarkdownListRow: View {
    let marker: String
    let content: String
    @Environment(\.markdownTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(theme.bodyFont)
                .foregroundStyle(.secondary)
            Text(InlineMarkdown.attributedString(from: content))
                .font(theme.bodyFont)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
