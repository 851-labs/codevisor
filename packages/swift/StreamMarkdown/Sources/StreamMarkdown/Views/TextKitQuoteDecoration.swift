#if canImport(AppKit) || canImport(UIKit)
  import SwiftUI
  final class TextKitQuoteDecoration: NSObject, NSCopying {
    let color: MarkdownNativeColor
    let barOffsets: [CGFloat]
    let barWidth: CGFloat

    init(
      color: MarkdownNativeColor,
      barOffsets: [CGFloat],
      barWidth: CGFloat = MarkdownFragmentMetrics.quoteBarWidth
    ) {
      self.color = color
      self.barOffsets = barOffsets
      self.barWidth = barWidth
    }

    func copy(with _: NSZone? = nil) -> Any {
      self
    }
  }

  public enum TextKitQuoteBarPainter {
    public static func fill(_ rect: CGRect, color: MarkdownNativeColor, in context: CGContext) {
      context.saveGState()
      context.setFillColor(color.cgColor)
      context.fill(snapped(rect, in: context))
      context.restoreGState()
    }

    static func snapped(_ rect: CGRect, in context: CGContext) -> CGRect {
      let device = context.convertToDeviceSpace(rect)
      let minX = device.minX.rounded()
      let minY = device.minY.rounded()
      let maxX = max(minX + 1, device.maxX.rounded())
      let maxY = max(minY + 1, device.maxY.rounded())
      return context.convertToUserSpace(
        CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
  }

#endif
