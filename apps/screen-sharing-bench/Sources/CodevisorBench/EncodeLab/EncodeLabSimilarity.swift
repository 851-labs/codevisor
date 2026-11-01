import ScreenSharingBench

enum EncodeLabSimilarity {
  static let identicalPSNR = BenchTextFidelity.identicalPSNR

  static func psnr(_ reference: [Float], _ decoded: [Float]) -> Double {
    min(identicalPSNR, BenchSimilarity.psnr(reference, decoded))
  }

  static func psnr(_ reference: [[Float]], _ decoded: [[Float]]) -> Double {
    min(identicalPSNR, BenchSimilarity.psnr(reference, decoded))
  }

  static func ssim(_ reference: [Float], _ decoded: [Float], width: Int, height: Int) throws -> Double {
    try BenchSimilarity.ssim(reference, decoded, width: width, height: height)
  }
}
