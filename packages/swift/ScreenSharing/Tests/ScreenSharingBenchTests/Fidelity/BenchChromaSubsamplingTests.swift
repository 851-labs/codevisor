import ScreenSharingBench
import Testing

struct BenchChromaSubsamplingTests {
  private static let red = BenchRGB(red: 255, green: 0, blue: 0)
  private static let blue = BenchRGB(red: 0, green: 0, blue: 255)

  @Test func flatChromaSurvivesTheRoundTrip() {
    let planes = BenchYCbCrPlanes(Self.image(width: 8, height: 6) { _, _ in Self.red })

    #expect(BenchChromaSubsampling.roundTrip420(planes) == planes)
  }

  @Test func oneColumnRedBlueStripesLoseTheDocumentedAmount() {
    let planes = BenchYCbCrPlanes(Self.image(width: 8, height: 6) { x, _ in x.isMultiple(of: 2) ? Self.red : Self.blue })
    let roundTrip = BenchChromaSubsampling.roundTrip420(planes)

    #expect(BenchSimilarity.psnr([planes.blue, planes.red], [planes.blue, planes.red]) == .infinity)
    #expect(abs(BenchSimilarity.psnr([planes.blue, planes.red], [roundTrip.blue, roundTrip.red]) - 10.734) < 0.001)
    #expect(roundTrip.luma == planes.luma)
  }

  private static func image(width: Int, height: Int, color: (Int, Int) -> BenchRGB) -> BenchRGBImage {
    var image = BenchRGBImage(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 3))
    for y in 0..<height {
      for x in 0..<width { image.setPixel(x: x, y: y, color(x, y)) }
    }
    return image
  }
}
