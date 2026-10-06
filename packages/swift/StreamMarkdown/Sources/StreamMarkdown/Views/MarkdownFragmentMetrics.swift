import CoreGraphics

public enum MarkdownFragmentMetrics {
  /// Bar plus the gap before quoted content.
  public static let quoteIndent: CGFloat = 16
  /// One list level. Markers sit inside this column and item content starts
  /// after it, so a nested list's markers line up under its parent's text.
  public static let listIndent: CGFloat = 24
  /// How far markers sit in from the column's leading edge.
  public static let listMarkerInset: CGFloat = 6
  /// Minimum space between a marker and its item's content.
  public static let listMarkerGap: CGFloat = 8
  public static let quoteBarWidth: CGFloat = 2

  /// Column for a list whose widest marker is `markerWidth`. Every renderer
  /// (TextKit, transcript fragments, SwiftUI) lays lists out through this, so
  /// bullet, ordered, and task lists share one geometry. Wide ordered markers
  /// first give up the inset, then widen the column, so they never touch the
  /// item's content.
  public static func listColumn(markerWidth: CGFloat) -> (markerInset: CGFloat, width: CGFloat) {
    let marker = ceil(markerWidth)
    let width = max(listIndent, marker + listMarkerGap)
    return (min(listMarkerInset, width - listMarkerGap - marker), width)
  }
}
