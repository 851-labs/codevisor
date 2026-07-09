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
}
