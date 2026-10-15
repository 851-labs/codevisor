#if canImport(UIKit) && !canImport(AppKit)
  import QuartzCore
  import UIKit

  final class UIKitTextKitRoundedBackground: NSObject, NSCopying {
    let color: UIColor
    let cornerRadius: CGFloat

    init(color: UIColor, cornerRadius: CGFloat) {
      self.color = color
      self.cornerRadius = cornerRadius
    }

    func copy(with _: NSZone? = nil) -> Any {
      self
    }
  }

  extension NSAttributedString.Key {
    static let streamMarkdownQuoteDecoration = NSAttributedString.Key(
      "com.851labs.codevisor.streamMarkdownQuoteDecoration")
    static let streamMarkdownRoundedBackground = NSAttributedString.Key(
      "com.851labs.codevisor.streamMarkdownRoundedBackground"
    )
  }

  final class UIKitStreamingTextLayoutManager: NSLayoutManager {
    var animationTime = CACurrentMediaTime()

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
      drawMarkdownQuoteBars(forGlyphRange: glyphsToShow, at: origin)
      drawRoundedBackgrounds(forGlyphRange: glyphsToShow, at: origin)
      super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
      guard let textStorage, glyphsToShow.length > 0 else {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        return
      }

      let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
      var drewRange = false
      textStorage.enumerateAttribute(
        .streamMarkdownFade,
        in: characters,
        options: [.longestEffectiveRangeNotRequired]
      ) { value, characterRange, _ in
        let glyphRange = self.glyphRange(
          forCharacterRange: characterRange,
          actualCharacterRange: nil
        )
        let visibleGlyphs = NSIntersectionRange(glyphRange, glyphsToShow)
        guard visibleGlyphs.length > 0 else { return }
        drewRange = true

        let opacity =
          (value as? StreamingTextFadeMetadata)?
          .opacity(at: self.animationTime) ?? 1
        let graphics = UIGraphicsGetCurrentContext()
        graphics?.saveGState()
        graphics?.setAlpha(opacity)
        super.drawGlyphs(forGlyphRange: visibleGlyphs, at: origin)
        graphics?.restoreGState()
      }

      if !drewRange {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
      }
    }

    private func drawRoundedBackgrounds(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
      guard let textStorage, glyphsToShow.length > 0 else { return }
      let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
      textStorage.enumerateAttribute(
        .streamMarkdownRoundedBackground,
        in: characters
      ) { value, characterRange, _ in
        guard let background = value as? UIKitTextKitRoundedBackground else { return }
        let glyphRange = self.glyphRange(
          forCharacterRange: characterRange,
          actualCharacterRange: nil
        )
        let visibleGlyphs = NSIntersectionRange(glyphRange, glyphsToShow)
        guard visibleGlyphs.length > 0 else { return }

        self.enumerateLineFragments(forGlyphRange: visibleGlyphs) {
          _, _, textContainer, lineGlyphRange, _ in
          let fragmentGlyphs = NSIntersectionRange(visibleGlyphs, lineGlyphRange)
          guard fragmentGlyphs.length > 0 else { return }
          var rect = self.boundingRect(
            forGlyphRange: fragmentGlyphs,
            in: textContainer
          )
          rect.origin.x += origin.x
          rect.origin.y += origin.y
          rect = rect.insetBy(dx: 0, dy: 0.5)
          let opacity =
            (textStorage.attribute(
              .streamMarkdownFade,
              at: characterRange.location,
              effectiveRange: nil
            ) as? StreamingTextFadeMetadata)?.opacity(at: self.animationTime) ?? 1
          let graphics = UIGraphicsGetCurrentContext()
          graphics?.saveGState()
          graphics?.setAlpha(opacity)
          background.color.setFill()
          UIBezierPath(
            roundedRect: rect,
            cornerRadius: min(background.cornerRadius, rect.height / 2)
          ).fill()
          graphics?.restoreGState()
        }
      }
    }
  }
#endif
