#if canImport(AppKit)
  import AppKit

  public final class PreparedStaticText: @unchecked Sendable {
    static let maximumBitmapPixels = 4_194_304

    let layout: PreparedNativeTextLayout
    let inset: CGFloat
    let size: CGSize
    let image: CGImage?
    let scale: CGFloat

    var text: NSAttributedString { layout.text }

    var byteCost: Int {
      (image.map { $0.bytesPerRow * $0.height } ?? 0) + layout.text.length * 48
    }

    init(layout: PreparedNativeTextLayout, inset: CGFloat, image: CGImage?, scale: CGFloat) {
      self.layout = layout
      self.inset = inset
      self.image = image
      self.scale = scale
      size = CGSize(width: layout.size.width + inset * 2, height: layout.size.height + inset * 2)
    }

    @concurrent
    public static func prepare(_ request: StaticTextRequest) async -> PreparedStaticText? {
      let text = request.makeText()
      guard
        let layout = try? PreparedNativeTextLayout(
          text: text,
          width: request.layout.containerWidth,
          wrapsText: request.layout.wrapsText
        )
      else { return nil }
      StaticTextLinkStyle.apply(to: layout)
      let inset = request.layout.inset
      let image = StaticTextBitmap.render(
        layout,
        inset: inset,
        scale: request.scale,
        appearance: request.appearance
      )
      return PreparedStaticText(layout: layout, inset: inset, image: image, scale: request.scale)
    }
  }

  enum StaticTextLinkStyle {
    static func apply(to layout: PreparedNativeTextLayout) {
      let range = NSRange(location: 0, length: layout.text.length)
      layout.text.enumerateAttribute(.link, in: range) { value, linkRange, _ in
        guard value != nil else { return }
        layout.manager.addTemporaryAttributes(
          [.foregroundColor: NSColor.linkColor, .underlineStyle: 0], forCharacterRange: linkRange)
      }
    }
  }

  enum StaticTextBitmap {
    static func render(
      _ layout: PreparedNativeTextLayout,
      inset: CGFloat,
      scale: CGFloat,
      appearance: NSAppearance.Name
    ) -> CGImage? {
      let size = CGSize(width: layout.size.width + inset * 2, height: layout.size.height + inset * 2)
      let pixelWidth = Int((size.width * scale).rounded(.up))
      let pixelHeight = Int((size.height * scale).rounded(.up))
      guard pixelWidth > 0, pixelHeight > 0,
        pixelWidth * pixelHeight <= PreparedStaticText.maximumBitmapPixels,
        let context = bitmapContext(width: pixelWidth, height: pixelHeight)
      else { return nil }
      context.translateBy(x: 0, y: CGFloat(pixelHeight))
      context.scaleBy(x: scale, y: -scale)
      draw(layout, origin: CGPoint(x: inset, y: inset), in: context, appearance: appearance)
      return context.makeImage()
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
      )
    }

    private static func draw(
      _ layout: PreparedNativeTextLayout,
      origin: CGPoint,
      in context: CGContext,
      appearance: NSAppearance.Name
    ) {
      let graphics = NSGraphicsContext(cgContext: context, flipped: true)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = graphics
      (NSAppearance(named: appearance) ?? NSAppearance(named: .aqua))?.performAsCurrentDrawingAppearance {
        let glyphs = layout.manager.glyphRange(for: layout.container)
        layout.manager.drawBackground(forGlyphRange: glyphs, at: origin)
        layout.manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
      }
      NSGraphicsContext.restoreGraphicsState()
    }
  }
#endif
