// Pure-SwiftUI fallback retained for non-AppKit platforms and portable
// previews. Native iOS transcript prose uses the UIKit/TextKit renderer;
// portable tables still reuse `portableInlineText` for their cells.
#if !canImport(AppKit)
import SwiftUI

struct MarkdownPortableTextRunView: View {
    let blocks: [MarkdownBlock]
    let foregroundColor: Color
    @Environment(\.markdownTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { _, block in
                blockView(block)
            }
        }
        .lineSpacing(theme.lineSpacing)
        .foregroundStyle(foregroundColor)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(InlineMarkdown.attributedString(from: text, theme: theme))
                .font(headingFont(level))
                .bold()
        case let .paragraph(text):
            portableInlineText(text, theme: theme)
        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        portableInlineText(item, theme: theme)
                    }
                }
            }
        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.number).")
                            .monospacedDigit()
                        portableInlineText(item.text, theme: theme)
                    }
                }
            }
        default:
            // Code blocks, quotes, tables, and rules are dispatched to their
            // own views by MarkdownBlockView before reaching a text run.
            EmptyView()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }
}

#endif
