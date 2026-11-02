import CoreVideo

struct ScreenSharingV2PixelPlane {
  let index: Int?

  static func planes(of buffer: CVPixelBuffer) -> [ScreenSharingV2PixelPlane] {
    guard CVPixelBufferIsPlanar(buffer) else { return [ScreenSharingV2PixelPlane(index: nil)] }

    return (0..<CVPixelBufferGetPlaneCount(buffer)).map { ScreenSharingV2PixelPlane(index: $0) }
  }

  func base(of buffer: CVPixelBuffer) -> UnsafeMutableRawPointer? {
    guard let index else { return CVPixelBufferGetBaseAddress(buffer) }

    return CVPixelBufferGetBaseAddressOfPlane(buffer, index)
  }

  func height(of buffer: CVPixelBuffer) -> Int {
    guard let index else { return CVPixelBufferGetHeight(buffer) }

    return CVPixelBufferGetHeightOfPlane(buffer, index)
  }

  func bytesPerRow(of buffer: CVPixelBuffer) -> Int {
    guard let index else { return CVPixelBufferGetBytesPerRow(buffer) }

    return CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
  }

  func rows(_ rows: Range<Int>, of buffer: CVPixelBuffer, height: Int) -> Range<Int> {
    let planeHeight = self.height(of: buffer)
    let lower = rows.lowerBound * planeHeight / height
    let upper = min(planeHeight, (rows.upperBound * planeHeight + height - 1) / height)
    return lower..<upper
  }
}
