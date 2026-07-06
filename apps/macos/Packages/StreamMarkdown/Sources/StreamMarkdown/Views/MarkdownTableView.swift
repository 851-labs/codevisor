import SwiftUI

/// Renders a GFM table using a grid with column alignments.
struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]

    @Environment(\.markdownTheme) private var theme

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    cell(header, alignment: alignment(at: index), isHeader: true)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                        cell(value, alignment: alignment(at: index), isHeader: false)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.tableBorderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func alignment(at index: Int) -> ColumnAlignment {
        index < alignments.count ? alignments[index] : .none
    }

    private func cell(_ text: String, alignment: ColumnAlignment, isHeader: Bool) -> some View {
        Text.withInlineCodeChips(InlineMarkdown.attributedString(from: text, theme: theme))
            .font(isHeader ? theme.bodyFont.weight(.semibold) : theme.bodyFont)
            .textRenderer(InlineCodeChipRenderer(background: theme.inlineCodeBackground))
            .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    private func frameAlignment(_ alignment: ColumnAlignment) -> Alignment {
        switch alignment {
        case .leading, .none: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

#Preview {
    MarkdownTableView(
        headers: ["Name", "Age", "City"],
        alignments: [.leading, .center, .trailing],
        rows: [["Ann", "30", "New York"], ["Bob", "25", "LA"]]
    )
    .padding()
    .frame(width: 420)
}
