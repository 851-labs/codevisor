#if canImport(AppKit)
  import AppKit

  @testable import StreamMarkdown

  extension TableTextView {
    func paintsEdges(redrawing strip: NSRect) -> Bool {
      guard let bitmap = bitmapImageRepForCachingDisplay(in: strip) else { return false }
      cacheDisplay(in: strip, to: bitmap)
      let edges = [0, bitmap.pixelsWide - 1]
      return edges.allSatisfy { (bitmap.colorAt(x: $0, y: 0)?.alphaComponent ?? 0) > 0 }
    }

    func rowBottoms() -> [CGFloat] {
      guard let layoutManager, let textStorage else { return [] }
      var bottoms: [Int: CGFloat] = [:]
      textStorage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: textStorage.length)) {
        value, range, _ in
        guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bottom = layoutManager.boundsRect(for: block, glyphRange: glyphs).maxY
        bottoms[block.startingRow] = max(bottoms[block.startingRow] ?? 0, bottom)
      }
      return bottoms.keys.sorted().compactMap { bottoms[$0] }
    }
  }
#endif
