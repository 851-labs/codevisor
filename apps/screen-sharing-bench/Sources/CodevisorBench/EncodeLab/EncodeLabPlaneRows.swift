import CoreVideo

struct EncodeLabPlaneRows {
  let index: Int?
  let height: Int

  static func planes(of buffer: CVPixelBuffer) -> [EncodeLabPlaneRows] {
    guard CVPixelBufferIsPlanar(buffer) else {
      return [EncodeLabPlaneRows(index: nil, height: CVPixelBufferGetHeight(buffer))]
    }

    return (0..<CVPixelBufferGetPlaneCount(buffer)).map {
      EncodeLabPlaneRows(index: $0, height: CVPixelBufferGetHeightOfPlane(buffer, $0))
    }
  }

  func rows(ofTile tile: Int, tiles: Int) -> Range<Int> {
    let tileRows = height / tiles
    return tile * tileRows..<(tile + 1) * tileRows
  }

  func bytesPerRow(_ buffer: CVPixelBuffer) -> Int {
    guard let index else { return CVPixelBufferGetBytesPerRow(buffer) }

    return CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
  }

  func base(_ buffer: CVPixelBuffer) -> UnsafeMutableRawPointer {
    guard let index else { return CVPixelBufferGetBaseAddress(buffer)! }

    return CVPixelBufferGetBaseAddressOfPlane(buffer, index)!
  }
}
