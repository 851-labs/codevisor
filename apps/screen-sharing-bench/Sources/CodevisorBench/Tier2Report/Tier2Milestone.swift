import ScreenSharingBench

struct Tier2Milestone {
  static let system = BenchSystem.codevisorV2
  static let p50AboveFloorMs = 17.0
  static let p95AboveFloorMs = 50.0
  static let idleCursorMbps = 0.5
  static let idleScene = "idle-cursor"
  static let lossyNetwork = "N3"
  static let shownRatio = 0.9
  static let secondsScaleMs = 1000.0

  let report: BenchReport
  let floors: Tier2Floors

  var text: String? {
    let groups = Tier2Group.all(report.results.filter { $0.system == Self.system })
    guard !groups.isEmpty else { return nil }

    let header = [
      "### M2 targets (\(Self.system.rawValue), median of valid repetitions)", "",
      "p50 at most floor + \(Int(Self.p50AboveFloorMs)) ms and p95 at most the floor's p95 + "
        + "\(Int(Self.p95AboveFloorMs)) ms (the floor of the same scene and network), idle-cursor at most "
        + "\(Self.idleCursorMbps) Mbit/s, \(Self.lossyNetwork) shown ratio at least \(Self.shownRatio), and no image "
        + "older than \(Int(Self.secondsScaleMs)) ms.", "",
      "| Scene | Resolution | Network | p50 − floor | p95 − floor p95 | Mbit/s p50 | Shown | Max image age ms "
        + "| Result |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    return (header + groups.map(row)).joined(separator: "\n")
  }

  private func row(_ group: Tier2Group) -> String {
    let valid = report.results.filter { group.contains($0) && $0.system == Self.system && $0.valid }
    let p50 = median(valid) { $0.imageAgeMs?.p50 }
    let p95 = median(valid) { $0.imageAgeMs?.p95 }
    let p50AboveFloor = difference(p50, floors.p50(scene: group.scene, network: group.network))
    let p95AboveFloor = difference(p95, floors.p95(scene: group.scene, network: group.network))
    let bitrate = median(valid) { $0.bitrateMbps?.p50 }
    let shown = median(valid) { $0.shownRatio }
    let oldest = valid.compactMap(\.imageAgeMs?.max).max()
    let checks = [
      p50AboveFloor.map { $0 <= Self.p50AboveFloorMs }, p95AboveFloor.map { $0 <= Self.p95AboveFloorMs },
      group.scene == Self.idleScene ? bitrate.map { $0 <= Self.idleCursorMbps } : true,
      group.network == Self.lossyNetwork ? shown.map { $0 >= Self.shownRatio } : true,
      oldest.map { $0 < Self.secondsScaleMs },
    ]
    let cells = [
      group.scene, group.resolution, group.network, Tier2Format.number(p50AboveFloor),
      Tier2Format.number(p95AboveFloor), Tier2Format.number(bitrate), Tier2Format.number(shown),
      Tier2Format.number(oldest), result(valid.isEmpty ? [nil] : checks),
    ]
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private func result(_ checks: [Bool?]) -> String {
    if checks.contains(false) { return "❌ missed" }
    return checks.contains(nil) ? "– not measured" : "✅ met"
  }

  private func difference(_ value: Double?, _ floor: Double?) -> Double? {
    guard let value, let floor else { return nil }

    return value - floor
  }

  private func median(_ results: [BenchResult], _ value: (BenchResult) -> Double?) -> Double? {
    BenchSystemComparison.median(results.compactMap(value))
  }
}
