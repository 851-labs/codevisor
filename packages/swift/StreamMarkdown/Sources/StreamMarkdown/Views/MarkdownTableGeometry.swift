import CoreGraphics

/// Immutable geometry shared by table preparation and viewport mounting.
/// Finding visible cells uses two binary searches per axis.
struct MarkdownTableGeometry {
  let columnOffsets: [CGFloat]
  let rowOffsets: [CGFloat]

  init(columnWidths: [CGFloat], rowHeights: [CGFloat]) {
    columnOffsets = Self.offsets(columnWidths)
    rowOffsets = Self.offsets(rowHeights)
  }

  var size: CGSize {
    CGSize(width: columnOffsets.last ?? 0, height: rowOffsets.last ?? 0)
  }

  static func viewport(in bounds: CGRect, visible: CGRect, overscan: CGFloat = 80) -> CGRect {
    // Horizontal clipping belongs to the table's own scroller. Navigation
    // transitions can move the enclosing viewport sideways without changing
    // which table rows need to be prepared.
    CGRect(x: bounds.minX, y: visible.minY, width: bounds.width, height: visible.height)
      .insetBy(dx: 0, dy: -max(0, overscan)).intersection(bounds)
  }

  func rows(intersecting rect: CGRect) -> Range<Int> {
    Self.intersections(rect.minY, rect.maxY, offsets: rowOffsets)
  }

  func columns(intersecting rect: CGRect) -> Range<Int> {
    Self.intersections(rect.minX, rect.maxX, offsets: columnOffsets)
  }

  func frame(row: Int, column: Int) -> CGRect {
    CGRect(
      x: columnOffsets[column], y: rowOffsets[row],
      width: columnOffsets[column + 1] - columnOffsets[column],
      height: rowOffsets[row + 1] - rowOffsets[row]
    )
  }

  private static func offsets(_ lengths: [CGFloat]) -> [CGFloat] {
    var result: [CGFloat] = [0]
    result.reserveCapacity(lengths.count + 1)
    for length in lengths { result.append(result.last! + max(1, length)) }
    return result
  }

  private static func intersections(_ start: CGFloat, _ end: CGFloat, offsets: [CGFloat]) -> Range<Int> {
    let count = max(0, offsets.count - 1)
    guard count > 0, end > start, end > 0, start < offsets[count] else { return 0..<0 }
    func boundary(_ value: CGFloat, inclusive: Bool) -> Int {
      var low = 0
      var high = offsets.count
      while low < high {
        let middle = low + (high - low) / 2
        if offsets[middle] < value || (inclusive && offsets[middle] == value) {
          low = middle + 1
        } else {
          high = middle
        }
      }
      return low
    }
    let first = max(0, min(count, boundary(start, inclusive: true) - 1))
    let last = max(first, min(count, boundary(end, inclusive: false)))
    return first..<last
  }
}
