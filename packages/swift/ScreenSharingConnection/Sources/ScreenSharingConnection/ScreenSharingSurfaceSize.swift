public struct ScreenSharingSurfaceSize: Equatable, Sendable {
  public var width: Double
  public var height: Double
  public var scale: Double

  public init(width: Double, height: Double, scale: Double) {
    self.width = width
    self.height = height
    self.scale = scale
  }
}
