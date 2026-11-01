import Foundation

struct BenchFidelityTotals {
  private(set) var luma = BenchSquaredError.none
  private(set) var textLuma = BenchSquaredError.none
  private(set) var chroma = BenchSquaredError.none
  private(set) var chroma420 = BenchSquaredError.none
  private(set) var ssims: [Double] = []
  private(set) var deltaE00: [Double] = []

  mutating func addText(reference: BenchYCbCrPlanes, shown: BenchYCbCrPlanes, mask: [Bool]) throws {
    luma = luma + BenchSquaredError(reference.luma, shown.luma)
    textLuma = textLuma + BenchSquaredError(reference.luma, shown.luma, mask: mask)
    ssims.append(
      try BenchSimilarity.ssim(reference.luma, shown.luma, width: reference.width, height: reference.height))
  }

  mutating func addChroma(reference: BenchRGBImage, shown: BenchRGBImage, mask: [Bool]) {
    let referencePlanes = BenchYCbCrPlanes(reference)
    chroma = chroma + Self.chromaError(referencePlanes, BenchYCbCrPlanes(shown))
    chroma420 = chroma420 + Self.chromaError(referencePlanes, BenchChromaSubsampling.roundTrip420(referencePlanes))
    for index in mask.indices where mask[index] {
      let x = index % reference.width
      let y = index / reference.width
      deltaE00.append(
        BenchCIEDE2000.difference(
          BenchLab(reference.pixel(x: x, y: y)), BenchLab(shown.pixel(x: x, y: y))))
    }
  }

  var fidelity: BenchTextFidelity {
    let sortedDeltaE = deltaE00.sorted()
    return BenchTextFidelity(
      psnrY: luma.psnr, psnrYText: textLuma.psnr, ssimY: ssims.isEmpty ? nil : ssims.reduce(0, +) / Double(ssims.count),
      psnrCbcr: chroma.psnr,
      deltaE00Mean: sortedDeltaE.isEmpty ? nil : sortedDeltaE.reduce(0, +) / Double(sortedDeltaE.count),
      deltaE00P95: sortedDeltaE.isEmpty ? nil : BenchDistribution.nearestRank(0.95, of: sortedDeltaE), oneToOne: true)
  }

  private static func chromaError(_ reference: BenchYCbCrPlanes, _ shown: BenchYCbCrPlanes) -> BenchSquaredError {
    BenchSquaredError(reference.blue, shown.blue) + BenchSquaredError(reference.red, shown.red)
  }
}
