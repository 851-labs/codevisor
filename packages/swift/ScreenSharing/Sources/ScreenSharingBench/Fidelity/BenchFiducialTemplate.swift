public struct BenchFiducialTemplate: Sendable, Equatable {
  private static let units = 16
  private static let outerRingUnits = 3
  private static let innerRingUnits = 5
  private static let black: Float = 0
  private static let white: Float = 255

  public let size: Int
  public let luma: [Float]

  public init(size: Int) {
    self.size = size
    luma = (0..<size * size).map { Self.value(x: $0 % size, y: $0 / size, size: size) }
  }

  init(size: Int, luma: [Float]) {
    self.size = size
    self.luma = luma
  }

  public static func value(x: Int, y: Int, size: Int) -> Float {
    let ring = min(min(x, y), min(size - 1 - x, size - 1 - y))
    let unit = size / units
    return ring < outerRingUnits * unit || ring >= innerRingUnits * unit ? black : white
  }

  func downsampled(by factor: Int) -> BenchFiducialTemplate {
    let plane = BenchLumaImage(width: size, height: size, luma: luma).downsampled(by: factor)
    return BenchFiducialTemplate(size: plane.width, luma: plane.luma)
  }
}
