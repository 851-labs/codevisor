import CoreVideo

struct EncodeLabChromaPlane {
  private let base: UnsafePointer<UInt8>
  private let stride: Int
  private let subsampled: Bool

  init(_ buffer: CVPixelBuffer) {
    base = UnsafePointer(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self))
    stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    subsampled = CVPixelBufferGetWidthOfPlane(buffer, 1) < CVPixelBufferGetWidthOfPlane(buffer, 0)
  }

  func pair(row: Int, column: Int) -> (blue: Float, red: Float) {
    let shift = subsampled ? 1 : 0
    let offset = (row >> shift) * stride + (column >> shift) * 2
    return (Float(base[offset]), Float(base[offset + 1]))
  }
}
