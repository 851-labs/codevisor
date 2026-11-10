#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  @MainActor
  final class MarkdownTableCellPainter {
    private final class CellText {
      let storage: NSTextStorage
      let manager = UIKitStreamingTextLayoutManager()
      let container: NSTextContainer

      init(_ text: NSAttributedString, width: CGFloat) {
        storage = NSTextStorage(attributedString: Self.linkColored(text))
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
      }

      func draw(at origin: CGPoint) {
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
      }

      private static func linkColored(_ text: NSAttributedString) -> NSAttributedString {
        let colored = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
          guard value != nil else { return }
          colored.addAttribute(.foregroundColor, value: UIColor.link, range: range)
        }
        return colored
      }
    }

    private static let cacheLimit = 256
    private weak var layout: UIKitMarkdownTableLayout?
    private var texts: [Int: CellText] = [:]

    func draw(_ layout: UIKitMarkdownTableLayout, in tableRect: CGRect, skipping skipped: Set<Int>) {
      reset(for: layout)
      let geometry = layout.geometry
      let columnCount = geometry.columnOffsets.count - 1
      for row in geometry.rows(intersecting: tableRect) {
        for column in geometry.columns(intersecting: tableRect) {
          let id = row * columnCount + column
          guard !skipped.contains(id) else { continue }

          let frame = Self.textFrame(geometry: geometry, row: row, column: column)
          text(id, layout: layout, row: row, column: column, width: frame.width).draw(at: frame.origin)
        }
      }
    }

    static func textFrame(geometry: MarkdownTableGeometry, row: Int, column: Int) -> CGRect {
      geometry.frame(row: row, column: column).insetBy(
        dx: MarkdownTableMetrics.horizontalPadding, dy: MarkdownTableMetrics.verticalPadding
      )
    }

    private func reset(for layout: UIKitMarkdownTableLayout) {
      guard self.layout !== layout || texts.count > Self.cacheLimit else { return }

      self.layout = layout
      texts.removeAll(keepingCapacity: true)
    }

    private func text(_ id: Int, layout: UIKitMarkdownTableLayout, row: Int, column: Int, width: CGFloat) -> CellText {
      if let cached = texts[id] { return cached }

      let text = CellText(layout.cells[row][column], width: max(1, width))
      texts[id] = text
      return text
    }
  }
#endif
