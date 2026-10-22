#if canImport(AppKit)
  import AppKit

  @MainActor
  enum StaticTextHitTesting {
    static func insertionIndex(in prepared: PreparedStaticText, at viewPoint: NSPoint) -> Int {
      let layout = prepared.layout
      guard layout.text.length > 0 else { return 0 }
      let point = containerPoint(viewPoint, in: prepared)
      var fraction: CGFloat = 0
      let glyph = layout.manager.glyphIndex(for: point, in: layout.container, fractionOfDistanceThroughGlyph: &fraction)
      let character = layout.manager.characterIndexForGlyph(at: glyph)
      let index = fraction > 0.5 ? character + 1 : character
      return min(max(0, index), layout.text.length)
    }

    static func rects(in prepared: PreparedStaticText, for range: NSRange) -> [NSRect] {
      let layout = prepared.layout
      let clamped = NSIntersectionRange(range, NSRange(location: 0, length: layout.text.length))
      guard clamped.length > 0 else { return [] }
      let glyphs = layout.manager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
      var rects: [NSRect] = []
      layout.manager.enumerateEnclosingRects(
        forGlyphRange: glyphs,
        withinSelectedGlyphRange: glyphs,
        in: layout.container
      ) { rect, _ in
        rects.append(rect.offsetBy(dx: prepared.inset, dy: prepared.inset))
      }
      return rects
    }

    static func link(in prepared: PreparedStaticText?, at viewPoint: NSPoint) -> Any? {
      guard let prepared, prepared.text.length > 0, isOverText(prepared, at: viewPoint) else { return nil }
      let index = insertionIndex(in: prepared, at: viewPoint)
      for candidate in [index, index - 1] where candidate >= 0 && candidate < prepared.text.length {
        let attributes = prepared.text.attributes(at: candidate, effectiveRange: nil)
        if let link = attributes[.link] ?? attributes[.streamMarkdownServerFileLink] { return link }
      }
      return nil
    }

    private static func isOverText(_ prepared: PreparedStaticText, at viewPoint: NSPoint) -> Bool {
      let layout = prepared.layout
      let point = containerPoint(viewPoint, in: prepared)
      let glyph = layout.manager.glyphIndex(for: point, in: layout.container)
      let bounds = layout.manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: layout.container)
      return bounds.insetBy(dx: -2, dy: -2).contains(point)
    }

    private static func containerPoint(_ viewPoint: NSPoint, in prepared: PreparedStaticText) -> NSPoint {
      NSPoint(x: viewPoint.x - prepared.inset, y: viewPoint.y - prepared.inset)
    }
  }
#endif
