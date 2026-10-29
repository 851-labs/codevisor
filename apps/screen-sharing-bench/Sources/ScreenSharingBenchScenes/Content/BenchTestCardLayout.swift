public struct BenchTestCardLayout: Sendable, Equatable {
  private static let fiducialPoints = 32
  private static let insetPoints = 8
  private static let gapBelowBarcodePoints = 16

  public let fiducialSize: Int
  public let inset: Int
  public let top: Int

  public init(canvas: BenchSceneCanvas, barcodeHeight: Int) {
    fiducialSize = canvas.pixels(Self.fiducialPoints)
    inset = canvas.pixels(Self.insetPoints)
    top = barcodeHeight + canvas.pixels(Self.gapBelowBarcodePoints)
  }
}
