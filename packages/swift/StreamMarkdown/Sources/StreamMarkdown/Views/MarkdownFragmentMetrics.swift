import CoreGraphics
import MarkdownCore
#if canImport(AppKit) || canImport(UIKit)
  import SwiftUI
#endif

public enum MarkdownFragmentMetrics {
  public static let quoteIndent: CGFloat = 16
  public static let listIndent: CGFloat = 24
  public static let listMarkerInset: CGFloat = 6
  public static let listMarkerGap: CGFloat = 8
  public static let quoteBarWidth: CGFloat = 2

  public static func contentIndent(of layout: MarkdownFragmentLayout?) -> CGFloat {
    guard let layout else { return 0 }
    return CGFloat(layout.quoteDepth) * quoteIndent + CGFloat(layout.listDepth) * listIndent
  }

  public static func quoteBarOffset(at index: Int, in layout: MarkdownFragmentLayout) -> CGFloat {
    CGFloat(index) * quoteIndent + CGFloat(layout.quoteListDepths[index]) * listIndent
  }

  public static func listColumn(markerWidth: CGFloat) -> (markerInset: CGFloat, width: CGFloat) {
    let marker = ceil(markerWidth)
    let width = max(listIndent, marker + listMarkerGap)
    return (min(listMarkerInset, width - listMarkerGap - marker), width)
  }

  #if canImport(AppKit) || canImport(UIKit)
    public static func listColumn(markers: [String]) -> (markerInset: CGFloat, width: CGFloat) {
      listColumn(
        markerWidth: markers.map {
          ($0 as NSString).size(withAttributes: [.font: MarkdownTextRunRenderer.listMarkerFont(for: $0)]).width
        }.max() ?? 0
      )
    }

    public static func markerOffset(
      _ marker: MarkdownFragmentLayout.ListMarker, in layout: MarkdownFragmentLayout
    ) -> CGFloat {
      CGFloat(layout.quotesEnclosing(listDepth: marker.depth)) * quoteIndent
        + CGFloat(max(0, marker.depth - 1)) * listIndent
        + listColumn(markers: [marker.text]).markerInset
    }
  #endif
}
