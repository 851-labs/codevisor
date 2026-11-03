import CoreVideo

struct ScreenSharingV2TilePixels: @unchecked Sendable {
  let buffers: [Int: CVPixelBuffer]
}
