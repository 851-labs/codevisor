import Foundation
import ScreenSharingBench

enum EncodeLabTable {
  static let header = [
    "Scene", "Config", "Chroma", "Encode ms p50 / p95", "First tile ms p50", "Prepare / submit ms p95", "Mbit/s", "Frame KB p50 / p95", "Tile pictures/frame", "First frame KB",
    "Refresh KB (ms)", "PSNR-Y mean / min", "PSNR-CbCr", "SSIM-Y mean / min", "Native PSNR-Y / SSIM-Y", "Decode ms p50", "Late / dropped",
  ]

  static func markdown(_ results: [EncodeLabResult]) -> String {
    let rows = [header, header.map { _ in "---" }] + results.map(row)
    return rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n") + "\n"
  }

  static func progressLine(_ result: EncodeLabResult) -> String {
    row(result).joined(separator: "  ")
  }

  private static func row(_ result: EncodeLabResult) -> [String] {
    guard result.error == nil else {
      return [result.scene, result.config.name, "error: \(result.error ?? "")"] + Array(repeating: "", count: header.count - 3)
    }

    return [
      result.scene, result.config.name, result.chroma ?? "?", pair(result.encodeMs), fixed(result.firstTileMs?.p50, 1),
      "\(fixed(result.prepareMs?.p95, 1)) / \(fixed(result.submitBlockMs?.p95, 1))", fixed(result.megabitsPerSecond, 2),
      pair(result.frameKilobytes, digits: 0), fixed(result.tilesPerFrame, 1), cost(result.firstFrame),
      cost(result.refresh), quality(result.quality), fixed(result.quality?.psnrCbCrMean, 1), similarity(result.quality), native(result.quality),
      fixed(result.decodeMs?.p50, 1), "\(result.lateSubmits) / \(result.dropped)",
    ]
  }

  private static func pair(_ distribution: BenchDistribution?, digits: Int = 1) -> String {
    guard let distribution else { return "–" }

    return "\(fixed(distribution.p50, digits)) / \(fixed(distribution.p95, digits))"
  }

  private static func cost(_ cost: EncodeLabFrameCost?) -> String {
    guard let cost else { return "–" }

    return "\(fixed(cost.kilobytes, 0)) (\(fixed(cost.encodeMs, 1)))"
  }

  private static func quality(_ quality: EncodeLabQualitySummary?) -> String {
    guard let quality else { return "–" }

    return "\(fixed(quality.psnrYMean, 1)) / \(fixed(quality.psnrYMin, 1))"
  }

  private static func similarity(_ quality: EncodeLabQualitySummary?) -> String {
    guard let quality else { return "–" }

    return "\(fixed(quality.ssimYMean, 4)) / \(fixed(quality.ssimYMin, 4))"
  }

  private static func native(_ quality: EncodeLabQualitySummary?) -> String {
    guard let psnr = quality?.nativePsnrYMean, let ssim = quality?.nativeSsimYMean else { return "–" }

    return "\(fixed(psnr, 1)) / \(fixed(ssim, 4))"
  }

  private static func fixed(_ value: Double?, _ digits: Int) -> String {
    guard let value else { return "–" }

    return String(format: "%.\(digits)f", value)
  }
}
