public struct BenchCardGeometry: Sendable, Equatable {
  public let canvasWidth: Int
  public let canvasHeight: Int
  public let fiducialSize: Int
  public let fiducialOrigins: [BenchPixelOffset]
  public let nonText: [BenchPixelRect]
  public let chromaTiles: [BenchPixelRect]

  public init(
    canvasWidth: Int, canvasHeight: Int, fiducialSize: Int, fiducialOrigins: [BenchPixelOffset],
    nonText: [BenchPixelRect], chromaTiles: [BenchPixelRect]
  ) {
    self.canvasWidth = canvasWidth
    self.canvasHeight = canvasHeight
    self.fiducialSize = fiducialSize
    self.fiducialOrigins = fiducialOrigins
    self.nonText = nonText
    self.chromaTiles = chromaTiles
  }

  public var canvas: BenchPixelRect {
    BenchPixelRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
  }

  public var fiducials: [BenchPixelRect] {
    fiducialOrigins.map { BenchPixelRect(x: $0.dx, y: $0.dy, width: fiducialSize, height: fiducialSize) }
  }
}
