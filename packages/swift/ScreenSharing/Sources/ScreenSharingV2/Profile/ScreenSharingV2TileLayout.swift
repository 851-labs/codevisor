import CoreGraphics

public struct ScreenSharingV2TileLayout: Equatable, Sendable {
  public static let rowAlignment = 16
  public static let maximumCount = 8
  private static let shortestTile = 64

  public let width: Int
  public let height: Int
  public let count: Int
  public let tileHeight: Int

  public init(width: Int, height: Int, count: Int) {
    let count = min(max(1, count), Self.maximumCount, max(1, height / Self.shortestTile))
    let stripe = (height + count - 1) / count
    let aligned = (stripe + Self.rowAlignment - 1) / Self.rowAlignment * Self.rowAlignment
    self.init(width: width, height: height, count: count, tileHeight: count == 1 ? height : aligned)
  }

  public init(width: Int, height: Int, count: Int, tileHeight: Int) {
    self.width = width
    self.height = height
    self.tileHeight = max(1, tileHeight)
    self.count = min(max(1, count), Self.maximumCount, (height + self.tileHeight - 1) / self.tileHeight)
  }

  public var tiles: Set<Int> { Set(0..<count) }

  public func rows(of tile: Int) -> Range<Int> {
    let start = min(height, tile * tileHeight)
    return start..<(tile == count - 1 ? height : min(height, start + tileHeight))
  }

  public func tiles(touching rects: [CGRect]?) -> Set<Int> {
    guard let rects, rects.allSatisfy(fits) else { return tiles }

    return rects.reduce(into: []) { touched, rect in touched.formUnion(tiles(touching: rect)) }
  }

  private func fits(_ rect: CGRect) -> Bool {
    rect.isEmpty || CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: -1, dy: -1).contains(rect)
  }

  private func tiles(touching rect: CGRect) -> Set<Int> {
    let top = max(0, Int(rect.minY.rounded(.down)))
    let bottom = min(height, Int(rect.maxY.rounded(.up)))
    guard rect.width > 0, bottom > top, rect.maxX > 0, rect.minX < CGFloat(width) else { return [] }

    return Set(min(count - 1, top / tileHeight)...min(count - 1, (bottom - 1) / tileHeight))
  }
}
