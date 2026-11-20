import AppKit
import Testing

@testable import StreamMarkdown

@MainActor
@Suite("Markdown table bidi layout")
struct MarkdownTableBidiLayoutTests {
  struct Table: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let headers: [String]
    let alignments: [ColumnAlignment]
    let rows: [[String]]
  }

  private struct LaidOut {
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let width: CGFloat
  }

  nonisolated static let multilingual = Table(
    testDescription: "multilingual",
    headers: ["Stage", "English", "中文", "日本語", "한국어", "العربية", "עברית", "Trace marker"],
    alignments: [.center, .none, .none, .none, .none, .none, .none, .trailing],
    rows: [
      ["1", "Source code", "源代码", "ソースコード", "소스 코드", "الشيفرة المصدرية", "קוד מקור", "`[1,2]`"],
      ["2", "Syntax tree", "语法树", "構文木", "구문 트리", "شجرة البنية النحوية", "עץ תחביר", "`[3,5]`"],
      ["4", "Stack", "栈", "スタック", "스택", "مكدّس", "מחסנית", "`[14,15]`"],
    ]
  )

  nonisolated static let tallCellAfterRTL = Table(
    testDescription: "tall cell after RTL",
    headers: ["A", "Arabic", "C", "D"],
    alignments: [],
    rows: [
      ["1", "العربية", "y", String(repeating: "long words wrap here ", count: 12)],
      ["2", "x", "مرحبا world", "z"],
    ]
  )

  @Test(
    "Cells after right-to-left text keep their column, row height, and fill in the transcript table",
    arguments: [(multilingual, 1200), (multilingual, 760), (multilingual, 320), (tallCellAfterRTL, 500)])
  func transcriptTable(_ table: Table, width: CGFloat) throws {
    try expectAlignedGrid(nativeTable(table, width: width), columns: table.headers.count)
  }

  @Test(
    "Cells after right-to-left text keep their column, row height, and fill in a prepared large table",
    arguments: [(multilingual, 760), (tallCellAfterRTL, 500)])
  func preparedTable(_ table: Table, width: CGFloat) throws {
    let parser = MarkdownParser()
    let content = PreparedTextContent.table(
      headers: table.headers.map(parser.parseInline), alignments: table.alignments,
      rows: table.rows.map { $0.map(parser.parseInline) }, theme: .default)
    let layout = try content.prepare(width: width, wrapsText: true)
    try expectAlignedGrid(
      LaidOut(storage: layout.storage, manager: layout.manager, width: layout.size.width),
      columns: table.headers.count)
  }

  private func nativeTable(_ table: Table, width: CGFloat) throws -> LaidOut {
    let parser = MarkdownParser()
    let view = NativeMarkdownTableBlockView(
      headers: table.headers.map(parser.parseInline), alignments: table.alignments,
      rows: table.rows.map { $0.map(parser.parseInline) }, theme: .default, linkAction: nil)
    view.frame = NSRect(x: 0, y: 0, width: width, height: view.contentHeight(forWidth: width))
    view.layoutSubtreeIfNeeded()
    let textView = try #require((view.subviews.first as? TableBleedContainer)?.scrollView.tableTextView)
    let manager = try #require(textView.layoutManager)
    let storage = try #require(textView.textStorage)
    manager.ensureLayout(for: try #require(textView.textContainer))
    return LaidOut(storage: storage, manager: manager, width: textView.bounds.width)
  }

  private func expectAlignedGrid(_ table: LaidOut, columns: Int) throws {
    let cells = cellBounds(table)
    let rows = Dictionary(grouping: cells, by: \.row)
    for column in 0..<columns {
      let edges = Set(cells.filter { $0.column == column }.map { [$0.rect.minX, $0.rect.maxX] })
      #expect(edges.count == 1, "column \(column) moves between rows: \(edges)")
    }
    for (row, rowCells) in rows {
      #expect(rowCells.count == columns, "row \(row) lost cells")
      #expect(Set(rowCells.map { [$0.rect.minY, $0.rect.maxY] }).count == 1, "row \(row) has uneven cells")
      let painted = rowCells.map(\.rect).reduce(CGRect.null) { $0.union($1) }
      #expect(painted.minX == 0 && painted.maxX == table.width, "row \(row) spans \(painted)")
    }
  }

  private func cellBounds(_ table: LaidOut) -> [(row: Int, column: Int, rect: CGRect)] {
    var cells: [(Int, Int, CGRect)] = []
    let full = NSRange(location: 0, length: table.storage.length)
    table.storage.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
      guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else { return }
      let glyphs = table.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      cells.append((block.startingRow, block.startingColumn, table.manager.boundsRect(for: block, glyphRange: glyphs)))
    }
    return cells
  }
}
