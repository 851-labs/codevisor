import CoreVideo

struct EncodeLabPreparedFrame: @unchecked Sendable {
  let version: Int
  let picture: CVPixelBuffer
  let inputs: [Int: CVPixelBuffer]
  let dirtyTiles: Set<Int>
}
