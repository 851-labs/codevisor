#if canImport(AppKit) || canImport(UIKit)
  import SwiftUI
  /// Quote bars carried by a flattened TextKit paragraph. Keeping the bars
  /// in the text layout lets nested quotes and list/quote mixtures remain a
  /// single selectable surface instead of rebuilding a recursive SwiftUI
  /// stack every time the virtualizer mounts the row.
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

  /// Fills quote bars on the device pixel grid.
  ///
  /// Quote bars are translucent (the theme's border color) and every
  /// renderer draws them in pieces — one per line fragment, layout fragment,
  /// or virtualized row. Pieces whose edges fall between pixels are
  /// antialiased, so neighbours either overlap (a darker band) or leave a
  /// hairline gap (a lighter one). Snapping both edges with the same rounding
  /// makes adjacent pieces tile exactly, so the bar reads as one solid rule.
  public enum TextKitQuoteBarPainter {
    public static func fill(_ rect: CGRect, color: MarkdownNativeColor, in context: CGContext) {
      context.saveGState()
      context.setFillColor(color.cgColor)
      context.fill(snapped(rect, in: context))
      context.restoreGState()
    }

    /// `rect` aligned to whole device pixels: each edge rounds independently
    /// so two rects sharing an edge share the same pixel boundary.
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
