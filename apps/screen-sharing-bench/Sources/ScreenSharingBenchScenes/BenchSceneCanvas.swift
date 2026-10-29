public struct BenchSceneCanvas: Sendable, Equatable, Codable {
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let scale: Int

  public init(pixelWidth: Int, pixelHeight: Int, scale: Int) {
    precondition(pixelWidth > 0 && pixelHeight > 0 && scale > 0, "A canvas needs a positive size and scale")
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.scale = scale
  }

  public init(_ resolution: BenchSceneResolution) {
    self.init(
      pixelWidth: resolution.pointWidth * resolution.scale, pixelHeight: resolution.pointHeight * resolution.scale,
      scale: resolution.scale)
  }

  public var pointWidth: Int { pixelWidth / scale }
  public var pointHeight: Int { pixelHeight / scale }

  func pixels(_ points: Int) -> Int {
    points * scale
  }
}
