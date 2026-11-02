struct BenchOffsetRange {
  let dx: ClosedRange<Int>
  let dy: ClosedRange<Int>

  init?(dx: (Int, Int), dy: (Int, Int)) {
    guard dx.0 <= dx.1, dy.0 <= dy.1 else { return nil }

    self.dx = dx.0...dx.1
    self.dy = dy.0...dy.1
  }

  var count: Int { dx.count * dy.count }

  var offsets: [BenchPixelOffset] {
    dy.flatMap { y in dx.map { BenchPixelOffset(dx: $0, dy: y) } }
  }

  func scaled(down factor: Int) -> BenchOffsetRange {
    BenchOffsetRange(
      dx: (Self.ceilingDivide(dx.lowerBound, factor), dx.upperBound / factor),
      dy: (Self.ceilingDivide(dy.lowerBound, factor), dy.upperBound / factor)) ?? self
  }

  func around(_ point: BenchPixelOffset, radius: Int) -> [BenchPixelOffset] {
    let center = BenchPixelOffset(dx: dx.clamp(point.dx), dy: dy.clamp(point.dy))
    let columns = max(dx.lowerBound, center.dx - radius)...min(dx.upperBound, center.dx + radius)
    let rows = max(dy.lowerBound, center.dy - radius)...min(dy.upperBound, center.dy + radius)
    return rows.flatMap { y in columns.map { BenchPixelOffset(dx: $0, dy: y) } }
  }

  private static func ceilingDivide(_ value: Int, _ divisor: Int) -> Int {
    value >= 0 ? (value + divisor - 1) / divisor : value / divisor
  }
}

extension ClosedRange<Int> {
  fileprivate func clamp(_ value: Int) -> Int {
    Swift.min(Swift.max(value, lowerBound), upperBound)
  }
}
