import ScreenSharingBench
import Testing

struct BenchTextFidelityAnalysisTests {
  private static let geometry = BenchFidelityImages.geometry

  @Test func identicalCapturesScoreAsIdentical() throws {
    let text = BenchFidelityImages.textCard()
    let chroma = BenchFidelityImages.chromaCard()
    let analysis = try #require(
      try BenchTextFidelityAnalysis(
        [
          BenchCardCapture(version: 4, kind: .text, reference: text, shown: text),
          BenchCardCapture(version: 6, kind: .chroma, reference: chroma, shown: chroma),
        ], geometry: Self.geometry))

    #expect(
      analysis.fidelity
        == BenchTextFidelity(
          psnrY: 100, psnrYText: 100, ssimY: 1, psnrCbcr: 100, deltaE00Mean: 0, deltaE00P95: 0, oneToOne: true))
    #expect(analysis.notOneToOneReason == nil)
  }

  @Test func aShownCaptureIsComparedAtItsRegisteredOffset() throws {
    let text = BenchFidelityImages.textCard()
    let shown = BenchFidelityImages.placed(text, width: 170, height: 100, at: BenchPixelOffset(dx: 3, dy: 2))
    let analysis = try #require(
      try BenchTextFidelityAnalysis(
        [BenchCardCapture(version: 4, kind: .text, reference: text, shown: shown)], geometry: Self.geometry))

    #expect(analysis.fidelity.psnrY == 100)
    #expect(analysis.fidelity.psnrCbcr == nil)
  }

  @Test func a420ShownChromaCardScoresLikeTheReferenceRoundTrip() throws {
    let chroma = BenchFidelityImages.chromaCard()
    let shown = Self.image(BenchChromaSubsampling.roundTrip420(BenchYCbCrPlanes(chroma)))
    let analysis = try #require(
      try BenchTextFidelityAnalysis(
        [BenchCardCapture(version: 6, kind: .chroma, reference: chroma, shown: shown)], geometry: Self.geometry))
    let psnrCbcr = try #require(analysis.fidelity.psnrCbcr)
    let roundTrip = try #require(analysis.reference420PsnrCbcr)

    #expect(abs(psnrCbcr - roundTrip) < 0.5)
    #expect(psnrCbcr < 40)
    #expect(try #require(analysis.fidelity.deltaE00Mean) > 1)
  }

  @Test func aHalfSizeViewerReportsNotOneToOneAndNoNumbers() throws {
    let text = BenchFidelityImages.textCard()
    let analysis = try #require(
      try BenchTextFidelityAnalysis(
        [BenchCardCapture(version: 5, kind: .text, reference: text, shown: BenchFidelityImages.halved(text))],
        geometry: Self.geometry))

    #expect(analysis.fidelity == .notOneToOne)
    #expect(analysis.notOneToOneReason == "version 5: viewer: the 80x48 capture is smaller than the 160x96 card")
  }

  private static func image(_ planes: BenchYCbCrPlanes) -> BenchRGBImage {
    var pixels = [UInt8]()
    for index in planes.luma.indices {
      let y = planes.luma[index]
      let red = y + 1.5748 * (planes.red[index] - 128)
      let blue = y + 1.8556 * (planes.blue[index] - 128)
      let green = (y - 0.2126 * red - 0.0722 * blue) / 0.7152
      pixels += [red, green, blue].map { UInt8(min(255, max(0, $0.rounded()))) }
    }
    return BenchRGBImage(width: planes.width, height: planes.height, pixels: pixels)
  }
}
