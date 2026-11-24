#if canImport(AppKit)
  import AppKit

  enum MarkdownTextTableGeometry {
    static func width(_ proposed: CGFloat) -> CGFloat {
      max(1, proposed).rounded(.up)
    }

    static func columns(_ widths: [CGFloat]) -> [CGFloat] {
      var boundary: CGFloat = 0
      var previous: CGFloat = 0
      return widths.map { width in
        boundary += width
        let next = boundary.rounded()
        defer { previous = next }
        return next - previous
      }
    }

    static func measured(in layoutManager: NSLayoutManager) -> MarkdownTableGeometry? {
      guard let storage = layoutManager.textStorage else { return nil }

      var rowEdges: [Int: CGFloat] = [:]
      var columnEdges: [Int: CGFloat] = [:]
      storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) {
        value, range, _ in
        guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else { return }

        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = layoutManager.boundsRect(for: block, glyphRange: glyphs)
        rowEdges[block.startingRow] = max(rowEdges[block.startingRow] ?? 0, bounds.maxY)
        columnEdges[block.startingColumn] = max(columnEdges[block.startingColumn] ?? 0, bounds.maxX)
      }
      guard !rowEdges.isEmpty else { return nil }

      return MarkdownTableGeometry(columnWidths: lengths(between: columnEdges), rowHeights: lengths(between: rowEdges))
    }

    private static func lengths(between edges: [Int: CGFloat]) -> [CGFloat] {
      var previous: CGFloat = 0
      return edges.values.sorted().map { edge in
        defer { previous = edge }
        return edge - previous
      }
    }
  }
#endif
