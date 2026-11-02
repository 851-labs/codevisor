import ScreenSharingBench

struct Tier2TextTable {
  let measurements: [Tier2Measurement]

  init(_ measurements: [Tier2Measurement]) {
    self.measurements = measurements.filter { $0.textFidelity != nil }
  }

  var text: String? {
    guard !measurements.isEmpty else { return nil }

    let header = [
      "| Run | System | Resolution | Viewer display | psnr_y | psnr_y_text | ssim_y | psnr_cbcr | 4:2:0 reference psnr_cbcr "
        + "| ΔE00 mean | ΔE00 p95 | Frames (text, chroma) | 1:1 |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    return "### Text fidelity (T8, test-cards)\n\n" + (header + measurements.compactMap(row)).joined(separator: "\n")
  }

  private func row(_ measurement: Tier2Measurement) -> String? {
    guard let analysis = measurement.textFidelity else { return nil }

    let meta = measurement.files.meta
    let fidelity = analysis.fidelity
    let numbers = [
      fidelity.psnrY, fidelity.psnrYText, fidelity.ssimY, fidelity.psnrCbcr, analysis.reference420PsnrCbcr,
      fidelity.deltaE00Mean, fidelity.deltaE00P95,
    ].map(Self.number)
    let oneToOne = analysis.notOneToOneReason.map { "not_1to1: \($0)" } ?? "yes"
    return
      "| \(measurement.files.directory.lastPathComponent) | \(meta.benchSystem?.rawValue ?? meta.system.rawValue) | "
      + "\(meta.resolutionLabel) | \(meta.viewerDisplay ?? "main") | " + numbers.joined(separator: " | ")
      + " | \(analysis.textFrames), \(analysis.chromaFrames) | \(oneToOne) |"
  }

  private static func number(_ value: Double?) -> String {
    guard let value else { return "–" }

    return value < 1.5 ? String(format: "%.4f", value) : String(format: "%.2f", value)
  }
}
