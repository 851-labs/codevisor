import Foundation
#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

struct TranscriptQuoteBadgeLayout {
  let title: String
  let font: OSFont
  let color: OSColor

  var size: CGSize {
    CGSize(width: ceil(Self.padding * 2 + iconSize.width + Self.iconGap + titleWidth), height: height)
  }

  var bounds: CGRect {
    CGRect(origin: CGPoint(x: 0, y: ((font.capHeight - height) / 2).rounded()), size: size)
  }

  func draw(in rect: CGRect) {
    color.withAlphaComponent(Self.fillOpacity).setFill()
    Self.roundedPath(rect, radius: (height * Self.cornerRatio).rounded()).fill()
    icon?.draw(in: iconRect(in: rect))
    (title as NSString).draw(
      with: titleRect(in: rect), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
      attributes: titleAttributes, context: nil)
  }

  private var height: CGFloat { ceil(font.ascender - font.descender) }

  private var titleFont: OSFont { .systemFont(ofSize: font.pointSize - 1, weight: .medium) }

  private var titleHeight: CGFloat { ceil(titleFont.ascender - titleFont.descender) }

  private var titleWidth: CGFloat {
    let natural = (title as NSString).size(withAttributes: [.font: titleFont]).width
    return min(ceil(natural), font.pointSize * Self.titleWidthInEms)
  }

  private var titleAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    return [.font: titleFont, .foregroundColor: color, .paragraphStyle: paragraph]
  }

  private var iconSize: CGSize { icon?.size ?? .zero }

  private func iconRect(in rect: CGRect) -> CGRect {
    let origin = CGPoint(x: rect.minX + Self.padding, y: rect.midY - iconSize.height / 2)
    return CGRect(origin: origin, size: iconSize)
  }

  private func titleRect(in rect: CGRect) -> CGRect {
    let x = rect.minX + Self.padding + iconSize.width + Self.iconGap
    return CGRect(x: x, y: rect.midY - titleHeight / 2, width: titleWidth, height: titleHeight)
  }

  private static let padding: CGFloat = 6
  private static let iconGap: CGFloat = 4
  private static let cornerRatio: CGFloat = 0.3
  private static let fillOpacity: CGFloat = 0.12
  private static let iconOpacity: CGFloat = 0.6
  private static let titleWidthInEms: CGFloat = 12
  private static let symbol = "text.quote"
}

#if canImport(AppKit)
  extension TranscriptQuoteBadgeLayout {
    private var icon: NSImage? {
      let configuration = NSImage.SymbolConfiguration(pointSize: titleFont.pointSize * 0.85, weight: .semibold)
        .applying(.init(paletteColors: [color.withAlphaComponent(Self.iconOpacity)]))
      return NSImage(systemSymbolName: Self.symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    }

    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }
  }
#elseif canImport(UIKit)
  extension TranscriptQuoteBadgeLayout {
    private var icon: UIImage? {
      let configuration = UIImage.SymbolConfiguration(pointSize: titleFont.pointSize * 0.85, weight: .semibold)
      return UIImage(systemName: Self.symbol, withConfiguration: configuration)?
        .withTintColor(color.withAlphaComponent(Self.iconOpacity), renderingMode: .alwaysOriginal)
    }

    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> UIBezierPath {
      UIBezierPath(roundedRect: rect, cornerRadius: radius)
    }
  }
#endif
