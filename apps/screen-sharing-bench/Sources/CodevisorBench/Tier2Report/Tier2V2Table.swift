import ScreenSharingBench

struct Tier2V2Table {
  private static let columns = 20

  private let results: [BenchResult]

  init(_ results: [BenchResult]) {
    self.results = results.filter { BenchSystem.engineV2Systems.contains($0.system) && $0.valid }
  }

  var text: String? {
    guard !results.isEmpty else { return nil }

    let header = [
      "### Engine v2 stages and counters (median of valid repetitions, whole session)", "",
      "| System | Scene | Resolution | Network | Encode p50 ms | Encode p95 ms | Send queue p50 | Send p50 "
        + "| Assemble p50 | Decode p50 | Render queue p50 | Present p50 | Frames lost | NACK repairs | FEC repairs "
        + "| LTR refreshes | LTR refreshes as keyframes | Keyframes "
        + "| Dropped before encode | Capacity Mbit/s |",
      "|" + String(repeating: " --- |", count: Self.columns),
    ]
    return (header + rows).joined(separator: "\n")
  }

  private var rows: [String] {
    BenchSystem.engineV2Systems.flatMap { system in
      Tier2Group.all(results).compactMap { group in
        let runs = results.filter { $0.system == system && group.contains($0) }
        return runs.isEmpty ? nil : row(system, group, runs: runs)
      }
    }
  }

  private func row(_ system: BenchSystem, _ group: Tier2Group, runs: [BenchResult]) -> String {
    let stages: [(BenchStageTimings) -> BenchDistribution?] = [
      \.encode, { $0.media?.queue }, { $0.media?.send }, { $0.media?.assemble }, \.decode, \.renderQueue, \.present,
    ]
    let counters: [(BenchMediaCounters) -> Double?] = [
      { Double($0.framesLost) }, { Double($0.nackRepairs) }, { Double($0.fecRepairs) }, { Double($0.ltrRefreshes) },
      { $0.ltrRefreshKeyframes.map(Double.init) }, { Double($0.keyframes) }, { Double($0.droppedBeforeEncode) },
      { $0.capacityKbps.map { Double($0) / 1000 } },
    ]
    let cells =
      [system.rawValue, group.scene, group.resolution, group.network]
      + [median(runs.compactMap { $0.stagesMs?.encode?.p50 }), median(runs.compactMap { $0.stagesMs?.encode?.p95 })]
      + stages.dropFirst().map { stage in median(runs.compactMap { $0.stagesMs.flatMap(stage)?.p50 }) }
      + counters.map { counter in median(runs.compactMap { $0.media.flatMap(counter) }) }
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private func median(_ values: [Double]) -> String {
    Tier2Format.number(BenchSystemComparison.median(values))
  }
}
