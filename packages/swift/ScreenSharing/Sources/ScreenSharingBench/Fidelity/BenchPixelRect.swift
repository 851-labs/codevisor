public struct BenchPixelRect: Sendable, Equatable, Codable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var maxX: Int { x + width }
  public var maxY: Int { y + height }

  public func contains(x px: Int, y py: Int) -> Bool {
    px >= x && px < maxX && py >= y && py < maxY
  }

  public func insetBy(_ amount: Int) -> BenchPixelRect {
    BenchPixelRect(
      x: x + amount, y: y + amount, width: max(0, width - 2 * amount), height: max(0, height - 2 * amount))
  }

  public func offsetBy(_ offset: BenchPixelOffset) -> BenchPixelRect {
    BenchPixelRect(x: x + offset.dx, y: y + offset.dy, width: width, height: height)
  }

  func fits(width outerWidth: Int, height outerHeight: Int) -> Bool {
    x >= 0 && y >= 0 && maxX <= outerWidth && maxY <= outerHeight
  }
}
