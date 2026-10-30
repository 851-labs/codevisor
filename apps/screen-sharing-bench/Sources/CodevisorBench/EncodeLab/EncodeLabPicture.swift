import CoreVideo

struct EncodeLabPicture {
  let width: Int
  let height: Int
  var luma: [Float]
  var blue: [Float]
  var red: [Float]

  init(width: Int, height: Int) {
    self.width = width
    self.height = height
    luma = Array(repeating: 0, count: width * height)
    blue = luma
    red = luma
  }

  mutating func paste(_ buffer: CVPixelBuffer, atRow top: Int) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let rows = max(0, min(CVPixelBufferGetHeight(buffer), height - top))
    let columns = min(width, CVPixelBufferGetWidth(buffer))
    let chroma = EncodeLabChromaPlane(buffer)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    for row in 0..<rows {
      let target = (top + row) * width
      for column in 0..<columns {
        luma[target + column] = Float(lumaBase[row * lumaStride + column])
        let pair = chroma.pair(row: row, column: column)
        blue[target + column] = pair.blue
        red[target + column] = pair.red
      }
    }
  }
}
