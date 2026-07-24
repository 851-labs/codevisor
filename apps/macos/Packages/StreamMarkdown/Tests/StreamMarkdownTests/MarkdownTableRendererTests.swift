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
