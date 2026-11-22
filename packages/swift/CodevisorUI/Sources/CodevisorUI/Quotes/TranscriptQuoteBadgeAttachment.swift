import Foundation
import TranscriptKit
#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

public final class TranscriptQuoteBadgeAttachment: NSTextAttachment {
  public let quote: TranscriptQuote
  private let layout: TranscriptQuoteBadgeLayout

  public init(quote: TranscriptQuote, font: OSFont, color: OSColor) {
    self.quote = quote
    layout = TranscriptQuoteBadgeLayout(title: quote.snippet, font: font, color: color)
    super.init(data: nil, ofType: nil)
    bounds = layout.bounds
    #if canImport(AppKit)
      image = Self.image(drawing: layout)
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  #if canImport(AppKit)
    private static func image(drawing layout: TranscriptQuoteBadgeLayout) -> NSImage {
      let image = NSImage(size: layout.size, flipped: false) { rect in
        layout.draw(in: rect)
        return true
      }
      image.cacheMode = .never
      return image
    }
  #elseif canImport(UIKit)
    private var renderedImages: [UIUserInterfaceStyle: UIImage] = [:]

    public override func image(
      forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int
    ) -> UIImage? {
      renderedImage()
    }

    public override func image(
      for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
      textContainer: NSTextContainer?
    ) -> UIImage? {
      renderedImage()
    }

    private func renderedImage() -> UIImage {
      let traits = UITraitCollection.current
      if let image = renderedImages[traits.userInterfaceStyle] { return image }

      let format = UIGraphicsImageRendererFormat(for: traits)
      let image = UIGraphicsImageRenderer(size: layout.size, format: format).image { [layout] _ in
        traits.performAsCurrent { layout.draw(in: CGRect(origin: .zero, size: layout.size)) }
      }
      renderedImages[traits.userInterfaceStyle] = image
      return image
    }
  #endif
}
