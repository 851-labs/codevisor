// Interim pure-SwiftUI renderers used where AppKit's TextKit views are
// unavailable (iOS). They render the same MarkdownBlock model via
// `InlineMarkdown.attributedString`, without selection or the chip/table
// finesse of the TextKit layer. The iOS transcript work replaces these with a
// UIKit/TextKit 2 counterpart; macOS never uses them.
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

struct MarkdownPortableTableView: View {
    let headers: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]
    @Environment(\.markdownTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        Text(InlineMarkdown.attributedString(from: header, theme: theme))
                            .bold()
                            .gridColumnAlignment(columnAlignment(index))
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            Text(InlineMarkdown.attributedString(from: cell, theme: theme))
                                .gridColumnAlignment(columnAlignment(index))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func columnAlignment(_ index: Int) -> HorizontalAlignment {
        guard index < alignments.count else { return .leading }
        switch alignments[index] {
        case .center: return .center
        case .trailing: return .trailing
        case .leading, .none: return .leading
        }
    }
}
#endif
