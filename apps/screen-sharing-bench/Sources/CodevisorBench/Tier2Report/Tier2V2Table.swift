import ScreenSharingBench

struct Tier2V2Table {
  private let results: [BenchResult]

  init(_ results: [BenchResult]) {
    self.results = results.filter { $0.system == .codevisorV2 && $0.valid }
  }

  var text: String? {
    guard !results.isEmpty else { return nil }

    let header = [
      "### Engine v2 stages and counters (median of valid repetitions, whole session)", "",
      "| Scene | Resolution | Network | Encode p50 ms | Send queue p50 | Send p50 | Assemble p50 | Decode p50 "
        + "| Render queue p50 | Present p50 | Frames lost | NACK repairs | FEC repairs | LTR refreshes | Keyframes "
        + "| Dropped before encode | Capacity Mbit/s |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    return (header + Tier2Group.all(results).map(row)).joined(separator: "\n")
  }

  private func row(_ group: Tier2Group) -> String {
    let runs = results.filter(group.contains)
    let stages: [(BenchStageTimings) -> BenchDistribution?] = [
      \.encode, { $0.media?.queue }, { $0.media?.send }, { $0.media?.assemble }, \.decode, \.renderQueue, \.present,
    ]
    let counters: [(BenchMediaCounters) -> Double?] = [
      { Double($0.framesLost) }, { Double($0.nackRepairs) }, { Double($0.fecRepairs) }, { Double($0.ltrRefreshes) },
      { Double($0.keyframes) }, { Double($0.droppedBeforeEncode) }, { $0.capacityKbps.map { Double($0) / 1000 } },
    ]
    let cells =
      [group.scene, group.resolution, group.network]
      + stages.map { stage in median(runs.compactMap { $0.stagesMs.flatMap(stage)?.p50 }) }
      + counters.map { counter in median(runs.compactMap { $0.media.flatMap(counter) }) }
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private func median(_ values: [Double]) -> String {
    Tier2Format.number(BenchSystemComparison.median(values))
  }
}
