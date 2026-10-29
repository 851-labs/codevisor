public struct BenchBarcodeLayout: Sendable, Equatable {
  public static let standard = BenchBarcodeLayout()
  public static let minimumBlockSize = 4

  public let x: Int
  public let y: Int
  public let blockSize: Int

  public init(x: Int = 0, y: Int = 0, blockSize: Int = 16) {
    precondition(blockSize >= Self.minimumBlockSize, "A barcode block needs at least 4×4 pixels")
    self.x = x
    self.y = y
    self.blockSize = blockSize
  }

  public var width: Int { blockSize * BenchBarcode.blockCount }
  public var height: Int { blockSize * 2 }

  func fits(width imageWidth: Int, height imageHeight: Int) -> Bool {
    x >= 0 && y >= 0 && x + width <= imageWidth && y + height <= imageHeight
  }
}
