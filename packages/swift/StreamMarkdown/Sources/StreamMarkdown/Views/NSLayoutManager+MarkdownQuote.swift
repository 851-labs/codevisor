#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  extension NSLayoutManager {
    func drawMarkdownQuoteBars(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
      guard let textStorage, glyphsToShow.length > 0 else { return }
      let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
      textStorage.enumerateAttribute(
        .streamMarkdownQuoteDecoration,
        in: characters,
        options: []
      ) { value, characterRange, _ in
        guard let decoration = value as? TextKitQuoteDecoration else { return }
        let glyphRange = self.glyphRange(
          forCharacterRange: characterRange,
          actualCharacterRange: nil
        )
        let visibleGlyphs = NSIntersectionRange(glyphRange, glyphsToShow)
        guard visibleGlyphs.length > 0 else { return }

        self.enumerateLineFragments(forGlyphRange: visibleGlyphs) {
          lineRect, _, _, lineGlyphRange, _ in
          guard NSIntersectionRange(visibleGlyphs, lineGlyphRange).length > 0 else {
            return
          }
          guard let context = UIGraphicsGetCurrentContext() else { return }
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

  }
#endif
