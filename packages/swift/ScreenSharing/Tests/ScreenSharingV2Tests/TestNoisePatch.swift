import ScreenSharing

struct TestNoisePatch {
  private static let rowsBetweenSeeds = 4_099

  let rows: Range<Int>
  let columns: Range<Int>
  let seed: Int

  func shade(row: Int, column: Int) -> UInt8 {
    TestBGRAPixels.noiseShade(row: row + seed * Self.rowsBetweenSeeds, column: column)
  }

  func painted(on shade: UInt8, timestampNs: Int64) throws -> ScreenSharingVideoFrame {
    let frame = try TestBGRAPixels.frame(shades: [shade], timestampNs: timestampNs)
    TestBGRAPixels.paint(frame.pixelBuffer, rows: rows, columns: columns, shade: self.shade)
    return frame
  }
}
