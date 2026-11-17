#if canImport(AppKit)
  import AppKit
  import SwiftUI

  @MainActor
  public enum MarkdownFragmentDecoration {
    public static func draw(_ layout: MarkdownFragmentLayout, theme: MarkdownTheme, in rect: NSRect) {
      drawQuoteBars(layout, color: NSColor(theme.quoteBarColor), in: rect)
      for marker in layout.listMarkers {
        draw(marker, in: layout, color: NSColor(theme.secondaryTextForeground), rect: rect)
      }
    }

    private static func drawQuoteBars(_ layout: MarkdownFragmentLayout, color: NSColor, in rect: NSRect) {
      guard let context = NSGraphicsContext.current?.cgContext else { return }

      for depth in 0..<layout.quoteDepth {
        let bar = NSRect(
          x: rect.minX + MarkdownFragmentMetrics.quoteBarOffset(at: depth, in: layout),
          y: rect.minY,
          width: MarkdownFragmentMetrics.quoteBarWidth,
          height: max(1, rect.height)
        )
        TextKitQuoteBarPainter.fill(bar, color: color, in: context)
      }
    }

    private static func draw(
      _ marker: MarkdownFragmentLayout.ListMarker, in layout: MarkdownFragmentLayout, color: NSColor, rect: NSRect
    ) {
      let x = rect.minX + MarkdownFragmentMetrics.markerOffset(marker, in: layout)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: MarkdownTextRunRenderer.listMarkerFont(for: marker.text),
        .foregroundColor: color,
      ]
      NSAttributedString(string: marker.text, attributes: attributes).draw(
        in: NSRect(x: x, y: rect.minY, width: max(1, rect.maxX - x), height: max(1, rect.height))
      )
    }
  }
#endif
