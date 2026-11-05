import ScreenSharingBench

struct Tier2BottomTable {
  private let measurements: [Tier2Measurement]

  init(_ measurements: [Tier2Measurement]) {
    self.measurements = measurements.filter { $0.invalidReason == nil && $0.bottom != nil && $0.result != nil }
  }

  var text: String? {
    guard !measurements.isEmpty else { return nil }

    let header = [
      "### Top and bottom tiles (second barcode, median of valid repetitions)", "",
      "Image age at the top-left barcode (the target table's) and at a second barcode in the bottom-left corner, "
        + "and the share of frames whose two barcodes show different versions (torn frames). The host draws both "
        + "barcodes in the same frame, so its torn share should be 0.", "",
      "| Scene | Resolution | Network | System | Top p50 ms | Top p95 | Bottom p50 ms | Bottom p95 "
        + "| Torn frames, viewer % | Torn frames, host % | Reps |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    return (header + rows).joined(separator: "\n")
  }

  private var rows: [String] {
    let results = measurements.compactMap(\.result)
    return Tier2Group.all(results).flatMap { group in
      BenchSystem.allCases.compactMap { system in
        let runs = measurements.filter { measurement in
          measurement.result.map { $0.system == system && group.contains($0) } == true
        }
        return runs.isEmpty ? nil : row(system, group, runs: runs)
      }
    }
  }

  private func row(_ system: BenchSystem, _ group: Tier2Group, runs: [Tier2Measurement]) -> String {
    let cells: [String] = [
      group.scene, group.resolution, group.network, system.rawValue,
      median(runs.compactMap { $0.result?.imageAgeMs?.p50 }), median(runs.compactMap { $0.result?.imageAgeMs?.p95 }),
      median(runs.compactMap { $0.bottom?.imageAgeMs?.p50 }), median(runs.compactMap { $0.bottom?.imageAgeMs?.p95 }),
      median(runs.compactMap { $0.bottom?.viewerTornFraction.map { $0 * 100 } }),
      median(runs.compactMap { $0.bottom?.hostTornFraction.map { $0 * 100 } }), String(runs.count),
    ]
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private func median(_ values: [Double]) -> String {
    Tier2Format.number(BenchSystemComparison.median(values))
  }
}
