#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
  extension NSLayoutManager {
    func drawMarkdownQuoteBars(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
      guard let textStorage, glyphsToShow.length > 0 else { return }
      #if canImport(AppKit)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
      #else
        guard let context = UIGraphicsGetCurrentContext() else { return }
      #endif

      // A paragraph and its spacing/newline can carry distinct decoration
      // instances on the same line. Enumerating attribute runs first paints
      // that line twice, darkening its translucent border. Quotes decorate
      // whole lines, so visit each line once and use its starting decoration.
      enumerateLineFragments(forGlyphRange: glyphsToShow) {
        lineRect, _, _, lineGlyphRange, _ in
        guard lineGlyphRange.length > 0 else { return }
        let character = self.characterIndexForGlyph(at: lineGlyphRange.location)
        guard character < textStorage.length,
          let decoration = textStorage.attribute(
            .streamMarkdownQuoteDecoration, at: character, effectiveRange: nil
          ) as? TextKitQuoteDecoration
        else { return }

        for offset in decoration.barOffsets {
          TextKitQuoteBarPainter.fill(
            CGRect(
              x: origin.x + offset,
              y: origin.y + lineRect.minY,
              width: decoration.barWidth,
              height: lineRect.height
            ),
            color: decoration.color,
            in: context
          )
        }
      }
    }
  }
#endif
