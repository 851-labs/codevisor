public struct BenchPixelOffset: Sendable, Equatable, Hashable, Codable {
  public var dx: Int
  public var dy: Int

  public init(dx: Int, dy: Int) {
    self.dx = dx
    self.dy = dy
  }

  public static let zero = BenchPixelOffset(dx: 0, dy: 0)

  static func + (lhs: BenchPixelOffset, rhs: BenchPixelOffset) -> BenchPixelOffset {
    BenchPixelOffset(dx: lhs.dx + rhs.dx, dy: lhs.dy + rhs.dy)
  }
}
