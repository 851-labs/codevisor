// Pure-SwiftUI table renderer used where AppKit's TextKit table view is
// unavailable (iOS). It mirrors the macOS table visually — the table fills
// the width it is given, columns share the platform-neutral
// `MarkdownTableMetrics.distribute` sizing (so long prose columns wrap while
// short columns keep their content on one line), and the chrome matches:
// shaded header row, row hairlines, rounded outer border, identical cell
// padding. What it does not offer is TextKit's cross-cell text selection —
// `NSTextTable` is an AppKit-only construct.
#if !canImport(AppKit)
import SwiftUI
import UIKit

struct MarkdownPortableTableView: View {
    let headers: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]
    @Environment(\.markdownTheme) private var theme
    @Environment(\.markdownTableBleed) private var bleed
    /// The width the transcript actually grants the table. Measured on the
    /// scroll host (a horizontal scroll view proposes nil width to its
    /// content, so the layout cannot learn it from its proposal).
    @State private var availableWidth: CGFloat?

    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        let columnCount = columnCount
        if columnCount > 0 {
            // The horizontal scroll view is the min-content escape hatch:
            // normally the table exactly fills `availableWidth` and nothing
            // scrolls, but when even min-content column widths don't fit the
            // viewport the table overflows sideways instead of compressing
            // into per-character-wrapped columns (which produced absurdly
            // tall rows on phones and broke the transcript's lazy layout).
            ScrollView(.horizontal, showsIndicators: false) {
                MarkdownTableGridLayout(
                    columnCount: columnCount,
                    targetWidth: availableWidth
                ) {
                    // Row-major cells: header row first, padded to columnCount
                    // so ragged rows still form a full grid (matching the
                    // macOS renderer's `prepareRow`).
                    ForEach(0..<((rows.count + 1) * columnCount), id: \.self) { index in
                        let row = index / columnCount
                        let column = index % columnCount
                        cell(row: row, column: column)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: MarkdownTableMetrics.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: MarkdownTableMetrics.cornerRadius)
                        .strokeBorder(theme.tableBorderColor, lineWidth: 1)
                )
            }
            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
            // Full-bleed viewport: the scroller escapes the host's text
            // padding (`markdownTableBleed` per side) so an overflowing table
            // scrolls all the way to the screen edges, while the content
            // margins keep it *resting* aligned with the text column. A
            // fitting table plus its margins exactly spans the widened
            // viewport, so nothing scrolls and the alignment is unchanged.
            .contentMargins(.horizontal, bleed, for: .scrollContent)
            .padding(.horizontal, -bleed)
            // Attached outside the negative padding, so it measures the text
            // column's width (the padding modifier reports proposal + insets)
            // — exactly the width a fitting table should fill.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                availableWidth = max(0, width)
            }
        }
    }

    private func markdown(row: Int, column: Int) -> String {
        let values = row == 0 ? headers : rows[row - 1]
        return column < values.count ? values[column] : ""
    }

    private func cell(row: Int, column: Int) -> some View {
        let isHeader = row == 0
        // Hairline beneath the header and every body row except the last —
        // the rounded outer border closes off the bottom (as on macOS).
        let showsHairline = row < rows.count
        var contentHasher = Hasher()
        contentHasher.combine(markdown(row: row, column: column))
        contentHasher.combine(isHeader)
        contentHasher.combine(theme.renderFingerprint)

        return portableInlineText(markdown(row: row, column: column), theme: theme)
            .fontWeight(isHeader ? .semibold : .regular)
            .padding(EdgeInsets(
                top: MarkdownTableMetrics.verticalPadding,
                leading: MarkdownTableMetrics.horizontalPadding,
                bottom: MarkdownTableMetrics.verticalPadding,
                trailing: MarkdownTableMetrics.horizontalPadding
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cellAlignment(column))
            .background(
                isHeader
                    ? Color.primary.opacity(MarkdownTableMetrics.headerBackgroundOpacity)
                    : Color.clear
            )
            .overlay(alignment: .bottom) {
                if showsHairline {
                    Rectangle()
                        .fill(theme.tableBorderColor)
                        .frame(height: 1)
                }
            }
            .layoutValue(key: TableCellContentKey.self, value: contentHasher.finalize())
            // SwiftUI `Text` has no min-content floor — proposed width 0 it
            // reports width 0 and wraps per character — so min-content is
            // measured with UIKit text metrics and handed to the layout.
            .layoutValue(
                key: TableCellMinimumWidthKey.self,
                value: TableCellMeasurement.minimumContentWidth(
                    markdown: markdown(row: row, column: column),
                    isHeader: isHeader,
                    theme: theme
                )
            )
    }

    private func cellAlignment(_ column: Int) -> Alignment {
        guard column < alignments.count else { return .topLeading }
        switch alignments[column] {
        case .center: return .top
        case .trailing: return .topTrailing
        case .leading, .none: return .topLeading
        }
    }
}

/// Fingerprint of a cell's render-affecting content. The layout re-measures
/// when any cell's fingerprint changes (streaming appends, theme switches);
/// `updateCache` alone only fires when the subview *list* changes, which would
/// miss in-place text growth in the last row.
private struct TableCellContentKey: LayoutValueKey {
    static let defaultValue: Int = 0
}

/// The cell's min-content width (widest unbreakable fragment plus padding),
/// measured with UIKit text metrics by the hosting view. SwiftUI subviews
/// cannot report this themselves: `Text` accepts any proposed width and wraps
/// per character, so a zero-width probe returns 0, not the widest word.
private struct TableCellMinimumWidthKey: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

/// Widest-word measurement for table cells, mirroring the macOS renderer's
/// `minimumContentWidth` but with UIKit fonts that match the metrics of the
/// theme's SwiftUI defaults (body text, semibold headers, monospaced callout
/// code). Memoized: streaming re-evaluates cell bodies far more often than
/// their content changes.
@MainActor
private enum TableCellMeasurement {
    private struct Key: Hashable {
        let markdown: String
        let isHeader: Bool
        let themeFingerprint: Int
    }

    private static var cache: [Key: CGFloat] = [:]
    private static var insertionOrder: [Key] = []
    private static var insertionHead = 0
    private static let limit = 4_096

    /// The widest whitespace-free fragment of the cell, including the cell's
    /// horizontal padding — the width below which word wrapping runs out and
    /// per-character breaking would begin.
    static func minimumContentWidth(
        markdown: String,
        isHeader: Bool,
        theme: MarkdownTheme
    ) -> CGFloat {
        let key = Key(
            markdown: markdown,
            isHeader: isHeader,
            themeFingerprint: theme.renderFingerprint
        )
        if let cached = cache[key] { return cached }

        let measured = measure(markdown: markdown, isHeader: isHeader, theme: theme)
            + MarkdownTableMetrics.horizontalPadding * 2
        cache[key] = measured
        insertionOrder.append(key)
        evictIfNeeded()
        return measured
    }

    private static func measure(
        markdown: String,
        isHeader: Bool,
        theme: MarkdownTheme
    ) -> CGFloat {
        let attributed = InlineMarkdown.attributedString(from: markdown, theme: theme)
        let bodySize = UIFont.preferredFont(forTextStyle: .body).pointSize
        let baseFont = UIFont.systemFont(
            ofSize: bodySize, weight: isHeader ? .semibold : .regular
        )
        let codeFont = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular
        )

        // A UIKit-measurable copy of the cell with per-run fonts.
        let measurable = NSMutableAttributedString()
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }
            let intent = run.inlinePresentationIntent
            let isCode = intent?.contains(.code) == true
                || run[InlineCodeChipAttribute.self] == true
            let font: UIFont
            if isCode {
                font = codeFont
            } else {
                font = styled(
                    baseFont,
                    bold: intent?.contains(.stronglyEmphasized) == true,
                    italic: intent?.contains(.emphasized) == true
                )
            }
            measurable.append(NSAttributedString(string: text, attributes: [.font: font]))
        }

        // Walk whitespace-free fragments and take the widest.
        let string = measurable.string
        var widest: CGFloat = 1
        var index = string.startIndex
        while index < string.endIndex {
            if string[index].isWhitespace {
                index = string.index(after: index)
                continue
            }
            let start = index
            while index < string.endIndex, !string[index].isWhitespace {
                index = string.index(after: index)
            }
            let fragment = measurable.attributedSubstring(
                from: NSRange(start..<index, in: string)
            )
            widest = max(widest, fragment.size().width)
        }
        return ceil(widest)
    }

    private static func styled(_ font: UIFont, bold: Bool, italic: Bool) -> UIFont {
        guard bold || italic else { return font }
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private static func evictIfNeeded() {
        while cache.count > limit, insertionHead < insertionOrder.count {
            cache.removeValue(forKey: insertionOrder[insertionHead])
            insertionHead += 1
        }
        if insertionHead > 1_024, insertionHead * 2 > insertionOrder.count {
            insertionOrder.removeFirst(insertionHead)
            insertionHead = 0
        }
    }
}

/// Lays table cells out on a fixed grid: each column's natural (single-line)
/// and min-content (widest-word) widths are measured through SwiftUI's own
/// text engine, `MarkdownTableMetrics.distribute` fits them to the proposed
/// width, and every cell in a row shares the row's height so header fills and
/// hairlines span cleanly.
///
/// Measurement contract per cell (`padding` + flexible `frame` wrapper):
/// - `sizeThatFits(.unspecified)` → ideal size: the unwrapped line plus padding.
/// - `sizeThatFits(width: 0)` → minimum: a flexible frame never reports less
///   than its child, and `Text` under a zero-width proposal reports its
///   min-content width (the widest word).
private struct MarkdownTableGridLayout: Layout {
    let columnCount: Int
    /// The transcript-granted width to fill, measured by the hosting view.
    /// The layout lives inside a horizontal scroll view, whose nil width
    /// proposal would otherwise leave the table at its natural (unwrapped)
    /// width. Nil until the first geometry pass.
    let targetWidth: CGFloat?

    struct Solution {
        var cellWidths: [CGFloat] = []
        var rowHeights: [CGFloat] = []
        var size: CGSize = .zero
    }

    struct Cache {
        var fingerprint: Int = 0
        var contentNaturalWidths: [CGFloat] = []
        var contentMinimumWidths: [CGFloat] = []
        /// Solutions per proposed width (a layout pass typically probes a few
        /// widths before settling). Cleared whenever the fingerprint changes.
        var solutions: [CGFloat: Solution] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) -> CGSize {
        solution(for: proposal, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) {
        let solution = solution(for: proposal, subviews: subviews, cache: &cache)
        guard !solution.cellWidths.isEmpty else { return }
        var y = bounds.minY
        for row in 0..<solution.rowHeights.count {
            let height = solution.rowHeights[row]
            var x = bounds.minX
            for column in 0..<columnCount {
                let index = row * columnCount + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: solution.cellWidths[column], height: height)
                )
                x += solution.cellWidths[column]
            }
            y += height
        }
    }

    private func solution(
        for proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) -> Solution {
        guard columnCount > 0, !subviews.isEmpty else { return Solution() }

        var hasher = Hasher()
        hasher.combine(columnCount)
        for subview in subviews {
            hasher.combine(subview[TableCellContentKey.self])
        }
        let fingerprint = hasher.finalize()
        if fingerprint != cache.fingerprint || cache.contentNaturalWidths.isEmpty {
            measureColumns(subviews: subviews, cache: &cache)
            cache.fingerprint = fingerprint
            cache.solutions.removeAll(keepingCapacity: true)
        }

        // Fill the measured transcript width (the horizontal scroll host
        // proposes nil). Before the first geometry pass — or under a direct
        // finite proposal — fall back to the proposal; nil/infinite lays the
        // table out at its natural width for one frame.
        let proposedWidth: CGFloat? =
            (proposal.width?.isFinite == true && proposal.width! > 0) ? proposal.width : nil
        let fitWidth = targetWidth ?? proposedWidth
        let solutionKey = fitWidth ?? -1
        if let cached = cache.solutions[solutionKey] { return cached }

        let padding = MarkdownTableMetrics.horizontalPadding * 2
        // compressesBelowMinimums: false — when min-content widths exceed
        // fitWidth the table overflows into the horizontal scroll view
        // instead of shredding columns below their widest word.
        let contentWidths = MarkdownTableMetrics.distribute(
            contentWidths: cache.contentNaturalWidths,
            minimumWidths: cache.contentMinimumWidths,
            toFit: fitWidth,
            compressesBelowMinimums: false
        )
        var solution = Solution()
        solution.cellWidths = contentWidths.map { $0 + padding }

        let rowCount = (subviews.count + columnCount - 1) / columnCount
        var heights = [CGFloat](repeating: 0, count: rowCount)
        for (index, subview) in subviews.enumerated() {
            let row = index / columnCount
            let column = index % columnCount
            let height = subview.sizeThatFits(
                ProposedViewSize(width: solution.cellWidths[column], height: nil)
            ).height
            heights[row] = max(heights[row], height)
        }
        solution.rowHeights = heights
        solution.size = CGSize(
            width: solution.cellWidths.reduce(0, +),
            height: heights.reduce(0, +)
        )
        cache.solutions[solutionKey] = solution
        return solution
    }

    private func measureColumns(subviews: Subviews, cache: inout Cache) {
        let padding = MarkdownTableMetrics.horizontalPadding * 2
        var naturals = [CGFloat](repeating: 1, count: columnCount)
        var minimums = [CGFloat](repeating: 1, count: columnCount)
        for (index, subview) in subviews.enumerated() {
            let column = index % columnCount
            let natural = subview.sizeThatFits(.unspecified).width - padding
            // Min-content comes from the cell's layout value: `Text` accepts
            // any proposed width (wrapping per character), so no proposal
            // probe can recover the widest-word width.
            let minimum = subview[TableCellMinimumWidthKey.self] - padding
            naturals[column] = max(naturals[column], natural)
            minimums[column] = max(minimums[column], min(minimum, natural))
        }
        cache.contentNaturalWidths = naturals
        cache.contentMinimumWidths = minimums
    }
}

#Preview {
    ScrollView {
        MarkdownPortableTableView(
            headers: ["Repo", "Lang", "What it is"],
            alignments: [.leading, .center, .leading],
            rows: [
                [
                    "zats/permiso", "Swift",
                    "Permission dialog for accessibility settings **as seen in Codex "
                        + "Computer Use**. SwiftPM package; API is "
                        + "`PermisoAssistant.shared.present(panel: .accessibility)`. "
                        + "Ships a sample app.",
                ],
                ["Ann", "30", "New York"],
            ]
        )
        .padding()
    }
}
#endif
