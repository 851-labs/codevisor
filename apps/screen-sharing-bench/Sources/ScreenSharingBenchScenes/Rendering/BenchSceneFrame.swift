import CoreVideo

public struct BenchSceneFrame: @unchecked Sendable {
  public let version: Int
  public let pixelBuffer: CVPixelBuffer
}
