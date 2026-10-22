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
      linkHit(in: prepared, at: viewPoint)?.value
    }

    static func linkRange(in prepared: PreparedStaticText?, at viewPoint: NSPoint) -> NSRange? {
      linkHit(in: prepared, at: viewPoint)?.range
    }

    static func underlineRects(in prepared: PreparedStaticText, for range: NSRange) -> [NSRect] {
      let layout = prepared.layout
      let clamped = NSIntersectionRange(range, NSRange(location: 0, length: layout.text.length))
      guard clamped.length > 0 else { return [] }
      let glyphs = layout.manager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
      var rects: [NSRect] = []
      layout.manager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, lineGlyphs, _ in
        let segment = NSIntersectionRange(lineGlyphs, glyphs)
        guard segment.length > 0 else { return }
        let character = layout.manager.characterIndexForGlyph(at: segment.location)
        let font = layout.text.attribute(.font, at: character, effectiveRange: nil) as? NSFont
        let baseline = line.minY + layout.manager.location(forGlyphAt: segment.location).y
        let thickness = max(1, font?.underlineThickness ?? 1)
        let bounds = layout.manager.boundingRect(forGlyphRange: segment, in: layout.container)
        rects.append(
          NSRect(
            x: bounds.minX + prepared.inset,
            y: baseline - (font?.underlinePosition ?? -1.5) - thickness / 2 + prepared.inset,
            width: bounds.width,
            height: thickness))
      }
      return rects
    }

    private static func linkHit(
      in prepared: PreparedStaticText?, at viewPoint: NSPoint
    ) -> (value: Any, range: NSRange)? {
      guard let prepared, prepared.text.length > 0, isOverText(prepared, at: viewPoint) else { return nil }
      let index = insertionIndex(in: prepared, at: viewPoint)
      for candidate in [index, index - 1] where candidate >= 0 && candidate < prepared.text.length {
        for key in [NSAttributedString.Key.link, .streamMarkdownServerFileLink] {
          var range = NSRange()
          if let value = prepared.text.attribute(key, at: candidate, effectiveRange: &range) { return (value, range) }
        }
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
