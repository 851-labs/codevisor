public struct BenchYCbCrPlanes: Sendable, Equatable {
  private static let redWeight: Float = 0.2126
  private static let greenWeight: Float = 0.7152
  private static let blueWeight: Float = 0.0722
  private static let blueScale: Float = 1.8556
  private static let redScale: Float = 1.5748
  static let chromaZero: Float = 128

  public let width: Int
  public let height: Int
  public var luma: [Float]
  public var blue: [Float]
  public var red: [Float]

  public init(_ image: BenchRGBImage) {
    width = image.width
    height = image.height
    let count = image.width * image.height
    luma = [Float](repeating: 0, count: count)
    blue = [Float](repeating: 0, count: count)
    red = [Float](repeating: 0, count: count)
    for index in 0..<count {
      let base = index * BenchRGBImage.channels
      let r = Float(image.pixels[base])
      let g = Float(image.pixels[base + 1])
      let b = Float(image.pixels[base + 2])
      let y = Self.redWeight * r + Self.greenWeight * g + Self.blueWeight * b
      luma[index] = y
      blue[index] = (b - y) / Self.blueScale + Self.chromaZero
      red[index] = (r - y) / Self.redScale + Self.chromaZero
    }
  }
}
