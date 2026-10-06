import CoreGraphics
import MarkdownCore

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

public extension MarkdownFragmentLayout {
  /// Where this row's text starts, after every ancestor list's marker
  /// column. A wide ordered marker widens its column past `listIndent`;
  /// indenting by the fixed width draws that marker on top of the text.
  public var listContentIndent: CGFloat {
    measuredListColumns.reduce(0) { $0 + $1.width }
  }

  /// Horizontal origin of a marker at `depth` (1 for the outermost list),
  /// in the same coordinate space as `listContentIndent`.
  public func listMarkerX(depth: Int) -> CGFloat {
    let index = depth - 1
    let columns = measuredListColumns
    guard columns.indices.contains(index) else { return 0 }
    return columns.prefix(index).reduce(CGFloat(0)) { $0 + $1.width } + columns[index].markerInset
  }

  private var measuredListColumns: [(markerInset: CGFloat, width: CGFloat)] {
    let levels =
      listLevels.isEmpty
      ? Array(repeating: "", count: listDepth)
      : listLevels.map(\.widestMarker)
    return levels.map { marker in
      #if canImport(AppKit) || canImport(UIKit)
        if !marker.isEmpty {
          return MarkdownFragmentMetrics.listColumn(markers: [marker])
        }
      #endif
      return (MarkdownFragmentMetrics.listMarkerInset, MarkdownFragmentMetrics.listIndent)
    }
  }
}
