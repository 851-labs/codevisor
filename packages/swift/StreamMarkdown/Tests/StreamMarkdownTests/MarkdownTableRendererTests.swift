import AppKit
import Foundation
import Testing

@testable import StreamMarkdown

@MainActor
@Suite("MarkdownTableRenderer")
struct MarkdownTableRendererTests {
    /// (row, column, bottom-border width) for each cell paragraph, in order.
    private func cells(
        _ attributed: NSAttributedString
    ) -> [(row: Int, column: Int, bottomBorder: CGFloat)] {
        var result: [(Int, Int, CGFloat)] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.paragraphStyle, in: full) { value, _, _ in
            guard let style = value as? NSParagraphStyle,
                let block = style.textBlocks.first as? NSTextTableBlock
            else { return }
            result.append(
                (block.startingRow, block.startingColumn, block.width(for: .border, edge: .maxY))
            )
        }
        return result
    }

    private func fullTSV(_ attributed: NSAttributedString) -> String? {
        TableTextView.tsv(from: attributed, in: NSRange(location: 0, length: attributed.length))
    }

    private func model(
        headers: [String] = ["Name", "Age"],
        rows: [[String]] = [["Ann", "30"], ["Bob", "25"]]
    ) -> TableModel {
        TableModel(headers: headers, alignments: [], rows: rows, theme: .default)
    }

    /// Lays an attributed string out in a TextKit 1 stack and returns the width
    /// it actually occupies at the given container width.
    private func laidOutWidth(_ attributed: NSAttributedString, containerWidth: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).width
    }

    @Test("A narrow table fills the width it is built for")
    func fillsWidth() {
        let attributed = MarkdownTableRenderer.make(
            headers: ["A", "B"], alignments: [], rows: [["x", "y"]], theme: .default, width: 800
        )
        let width = laidOutWidth(attributed, containerWidth: 800)
        #expect(width >= 780)
    }

    /// The width assigned to each column of a rendered table, by column index.
    private func columnWidths(_ attributed: NSAttributedString) -> [Int: CGFloat] {
        var result: [Int: CGFloat] = [:]
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.paragraphStyle, in: full) { value, _, _ in
            guard let style = value as? NSParagraphStyle,
                let block = style.textBlocks.first as? NSTextTableBlock
            else { return }
            result[block.startingColumn] = block.value(for: .width)
        }
        return result
    }

    @Test("A long prose column never crushes short columns below min-content")
    func shortColumnsKeepMinContentWidth() {
        // Regression: one dominant column used to shrink the scale factor so
        // far that "Swift"-sized columns got ~5pt and wrapped per character.
        let prose = String(
            repeating: "a fairly long description of the repository and what it does ",
            count: 8
        )
        let attributed = MarkdownTableRenderer.make(
            headers: ["Repo", "Lang", "What it is"], alignments: [],
            rows: [["zats/permiso", "Swift", prose]], theme: .default, width: 800
        )
        let widths = columnWidths(attributed)
        let repoMin = MarkdownTableRenderer.prepareCell(
            "zats/permiso", isHeader: false, theme: .default
        ).minimumWidth
        let langMin = MarkdownTableRenderer.prepareCell(
            "Swift", isHeader: false, theme: .default
        ).minimumWidth
        // Sanity: the min-content measurement is real, not a degenerate 1pt.
        #expect(repoMin > 20)
        #expect(langMin > 20)
        #expect(widths[0] ?? 0 >= repoMin)
        #expect(widths[1] ?? 0 >= langMin)
        // The prose column absorbs the squeeze (and wraps) instead.
        #expect(widths[2] ?? 0 > (widths[0] ?? 0) + (widths[1] ?? 0))
    }

    @Test("distribute keeps every column at its minimum and spends the budget")
    func distributeRespectsMinimums() {
        let widths = MarkdownTableMetrics.distribute(
            contentWidths: [60, 40, 2000],
            minimumWidths: [60, 40, 120],
            toFit: 500
        )
        // Zero-slack columns keep their natural width exactly.
        #expect(widths[0] >= 60)
        #expect(widths[1] >= 40)
        #expect(widths[2] >= 120)
        // The content budget (width minus 12pt padding per cell edge) is spent.
        let contentBudget: CGFloat = 500 - 12 * 2 * 3
        #expect(abs(widths.reduce(0, +) - contentBudget) < 1)
    }

    @Test("distribute degrades gracefully when even minimums cannot fit")
    func distributeOverconstrained() {
        let widths = MarkdownTableMetrics.distribute(
            contentWidths: [300, 300],
            minimumWidths: [200, 200],
            toFit: 120
        )
        #expect(widths.allSatisfy { $0 >= 1 })
        // Minimums shrink proportionally, so equal minimums stay equal.
        #expect(abs(widths[0] - widths[1]) < 0.001)
    }

    @Test("A table narrower than its widest words lays out at min-content width and overflows")
    @MainActor
    func overconstrainedTableKeepsMinContentColumns() {
        let theme = MarkdownTheme.default
        let long = String(repeating: "a", count: 80)
        let parser = MarkdownParser()
        let prepared = MarkdownTableRenderer.prepare(
            headers: ["Head", "Other"].map(parser.parseInline),
            rows: [[long, "x"].map(parser.parseInline)],
            theme: theme
        )
        let minimum = MarkdownTableMetrics.minimumTableWidth(
            columnMinimumWidths: prepared.columnMinimumWidths
        )
        #expect(minimum > 300)
        let cache = MarkdownTableRenderCache()
        let model = TableModel(
            headers: ["Head", "Other"], alignments: [.leading, .leading], rows: [[long, "x"]], theme: theme)
        #expect(cache.minimumWidth(for: model) == minimum)

        // Rendered at a width far narrower than the unbreakable word, every
        // column still keeps its min-content width instead of shredding.
        let attributed = MarkdownTableRenderer.make(
            prepared: prepared, alignments: [.leading, .leading], theme: theme, width: 200
        )
        var blockWidths: [Int: CGFloat] = [:]
        attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) {
            value, _, _ in
            guard let style = value as? NSParagraphStyle,
                let block = style.textBlocks.first as? NSTextTableBlock
            else { return }
            blockWidths[block.startingColumn] = block.value(for: .width)
        }
        #expect(blockWidths[0] ?? 0 >= prepared.columnMinimumWidths[0] - 0.5)
        #expect(blockWidths[1] ?? 0 >= prepared.columnMinimumWidths[1] - 0.5)
        #expect(cache.size(for: model, width: minimum).width >= minimum - 1)
    }

    @Test("distribute without compression keeps min-content and overflows")
    func distributeOverflowsInsteadOfCompressing() {
        // The iOS renderer's mode: a wide table on a narrow phone keeps every
        // column at min-content (readable, horizontally scrollable) rather
        // than shredding columns below their widest word.
        let widths = MarkdownTableMetrics.distribute(
            contentWidths: [300, 300],
            minimumWidths: [200, 180],
            toFit: 120,
            compressesBelowMinimums: false
        )
        #expect(widths == [200, 180])
    }

    @Test("A cell's minimum width is its widest word, not its full line")
    func minimumWidthIsWidestWord() {
        let cell = MarkdownTableRenderer.prepareCell(
            "several ordinary words in a sentence", isHeader: false, theme: .default
        )
        #expect(cell.minimumWidth < cell.naturalWidth)
        let word = MarkdownTableRenderer.prepareCell(
            "ordinary", isHeader: false, theme: .default
        )
        // The widest word here is "ordinary"/"sentence"-sized, far below the
        // full unwrapped line.
        #expect(cell.minimumWidth < word.naturalWidth * 2)
        #expect(cell.minimumWidth >= word.naturalWidth * 0.8)
        // A single word cannot wrap at all: its minimum is its natural width.
        #expect(word.minimumWidth == word.naturalWidth)
    }

    @Test("Every cell becomes a paragraph pinned to its row and column")
    func cellGrid() {
        let attributed = MarkdownTableRenderer.make(
            headers: ["Name", "Age"],
            alignments: [.leading, .trailing],
            rows: [["Ann", "30"], ["Bob", "25"]],
            theme: .default
        )
        let coords = Set(cells(attributed).map { "\($0.row),\($0.column)" })
        #expect(coords == ["0,0", "0,1", "1,0", "1,1", "2,0", "2,1"])
    }

    @Test("Every row but the last carries a hairline separator")
    func rowSeparators() {
        // Header (row 0) + 2 body rows (rows 1, 2). Rows 0 and 1 get a bottom
        // hairline; the last row (2) does not — the outer border closes it off.
        let attributed = MarkdownTableRenderer.make(
            headers: ["A", "B"], alignments: [],
            rows: [["1", "2"], ["3", "4"]], theme: .default
        )
        for cell in cells(attributed) {
            if cell.row < 2 {
                #expect(cell.bottomBorder > 0)
            } else {
                #expect(cell.bottomBorder == 0)
            }
        }
    }

    @Test("Copying the whole table yields tab-separated rows")
    func tsvFullTable() {
        let attributed = MarkdownTableRenderer.make(
            headers: ["Name", "Age"], alignments: [],
            rows: [["Ann", "30"], ["Bob", "25"]], theme: .default
        )
        #expect(fullTSV(attributed) == "Name\tAge\nAnn\t30\nBob\t25")
    }

    @Test("Ragged rows are padded to the widest row")
    func raggedRows() {
        let attributed = MarkdownTableRenderer.make(
            headers: ["A", "B", "C"], alignments: [],
            rows: [["1"], ["2", "3", "4"]], theme: .default
        )
        // 3 columns × (1 header + 2 body) = 9 cells, even though a row was short.
        #expect(cells(attributed).count == 9)
        #expect(fullTSV(attributed) == "A\tB\tC\n1\t\t\n2\t3\t4")
    }

    @Test("Inline markdown in a cell is parsed and its code keeps a background")
    func inlineCodeCell() {
        let attributed = MarkdownTableRenderer.make(
            headers: ["Call"], alignments: [], rows: [["`foo()`"]], theme: .default
        )
        var sawBackground = false
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.backgroundColor, in: full) { value, _, _ in
            if value != nil { sawBackground = true }
        }
        #expect(sawBackground)
        // Backticks are consumed by the inline parser, so copied text is clean.
        #expect(fullTSV(attributed) == "Call\nfoo()")
    }

    @Test("Server files and web URLs keep distinct link attributes")
    func linkAttributes() {
        let attributed = MarkdownTableRenderer.make(
            headers: ["Links"], alignments: [],
            rows: [["[Web](https://example.com) [File](</tmp/cat.png>)"]],
            theme: .default
        )
        let text = attributed.string as NSString
        let web = text.range(of: "Web")
        let file = text.range(of: "File")

        #expect(attributed.attribute(.link, at: web.location, effectiveRange: nil) != nil)
        #expect(
            attributed.attribute(
                .streamMarkdownServerFileLink,
                at: file.location,
                effectiveRange: nil
            ) != nil
        )
        #expect(attributed.attribute(.link, at: file.location, effectiveRange: nil) == nil)
    }

    @Test("A range with no table cells copies as nil (defers to default)")
    func tsvNoCells() {
        let plain = NSAttributedString(string: "not a table")
        #expect(TableTextView.tsv(from: plain, in: NSRange(location: 0, length: plain.length)) == nil)
        // Empty selection is also nil.
        let table = MarkdownTableRenderer.make(
            headers: ["A"], alignments: [], rows: [["1"]], theme: .default
        )
        #expect(TableTextView.tsv(from: table, in: NSRange(location: 0, length: 0)) == nil)
    }

    @Test("Measurement and display share one rendered table")
    func sharedMeasurementAndDisplayRender() {
        let cache = MarkdownTableRenderCache()
        let memo = MarkdownTableRenderMemo(cache: cache)
        let table = model()

        _ = memo.size(for: table, width: 420)
        let displayed = memo.attributedString(for: table, width: 420)
        let displayedAgain = memo.attributedString(for: table, width: 420)

        #expect(displayed === displayedAgain)
        #expect(cache.preparationCount == 1)
        #expect(cache.renderCount == 1)
        #expect(cache.measurementCount == 1)
    }

    @Test("Render cache retains multiple sizing widths")
    func retainsMultipleWidths() {
        let cache = MarkdownTableRenderCache()
        let table = model()

        let regular = cache.attributedString(for: table, width: 420)
        _ = cache.attributedString(for: table, width: 180)
        let regularAgain = cache.attributedString(for: table, width: 420)

        #expect(regular === regularAgain)
        #expect(cache.preparationCount == 1)
        #expect(cache.renderCount == 2)
    }

    @Test("Subpixel-equivalent widths share one rendered table")
    func normalizesEquivalentWidths() {
        let cache = MarkdownTableRenderCache()
        let table = model()

        let first = cache.attributedString(for: table, width: 420.1)
        let second = cache.attributedString(for: table, width: 420.2)

        #expect(first === second)
        #expect(cache.renderCount == 1)
    }

    @Test("Equivalent remounted tables reuse render and measurement")
    func remountReuse() {
        let cache = MarkdownTableRenderCache()
        let firstModel = model()
        let remountedModel = model()

        let first = cache.attributedString(for: firstModel, width: 420)
        _ = cache.size(for: firstModel, width: 420)
        let remounted = cache.attributedString(for: remountedModel, width: 420)
        _ = cache.size(for: remountedModel, width: 420)

        #expect(first === remounted)
        #expect(cache.preparationCount == 1)
        #expect(cache.renderCount == 1)
        #expect(cache.measurementCount == 1)
    }

    @Test("Growing tables only prepare newly introduced cell values")
    func growingTableReusesCells() {
        let cache = MarkdownTableRenderCache()
        let first = model(headers: ["Name", "Role"], rows: [["Ann", "Lead"]])
        let grown = model(
            headers: ["Name", "Role"],
            rows: [["Ann", "Lead"], ["Bob", "Engineer"]]
        )

        _ = cache.attributedString(for: first, width: 420)
        #expect(cache.cellPreparationCount == 4)
        _ = cache.attributedString(for: grown, width: 420)

        // The two headers and first row are cache hits; only Bob/Engineer are
        // new inline-Markdown preparations.
        #expect(cache.cellPreparationCount == 6)
        #expect(cache.preparationCount == 2)
        #expect(cache.renderCount == 2)
    }

    @Test("A table-heavy transcript does one build per table across size, display, and remount")
    func tableHeavyTranscriptReuse() {
        let cache = MarkdownTableRenderCache()
        let tables = (0..<40).map { index in
            model(
                headers: ["Key", "Value"],
                rows: [["Row \(index)", "Shared"]]
            )
        }

        for table in tables {
            let memo = MarkdownTableRenderMemo(cache: cache)
            _ = memo.size(for: table, width: 420)
            _ = memo.attributedString(for: table, width: 420)
        }
        for table in tables {
            let remountedMemo = MarkdownTableRenderMemo(cache: cache)
            _ = remountedMemo.size(for: table, width: 420)
            _ = remountedMemo.attributedString(for: table, width: 420)
        }

        #expect(cache.preparationCount == 40)
        #expect(cache.renderCount == 40)
        #expect(cache.measurementCount == 40)
        // Two shared headers, one shared body value, and forty distinct keys.
        #expect(cache.cellPreparationCount == 43)
    }
}
