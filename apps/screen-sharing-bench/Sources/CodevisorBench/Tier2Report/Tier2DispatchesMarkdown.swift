import ScreenSharingBench

struct Tier2DispatchesMarkdown {
  static let systems: [BenchSystem] = [.appleHP, .codevisorV2, .codevisorV2VCP]
  static let verdictMetrics = ["image_age_ms.p50", "image_age_ms.p95"]

  private let dispatches: [Tier2Dispatch]

  init(_ dispatches: [Tier2Dispatch]) {
    self.dispatches = dispatches
  }

  var text: String {
    ([regressions, dispatchTable, acrossTable, verdictTable].compactMap(\.self)).joined(separator: "\n\n") + "\n"
  }

  private var regressions: String? {
    let lines = dispatches.compactMap { dispatch -> String? in
      let parity = dispatch.parity
      guard !parity.regressions.isEmpty, let headline = parity.headline else { return nil }

      return "Dispatch \(dispatch.label): \(headline)"
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
  }

  private var dispatchTable: String {
    let header = [
      "## Tier 2 across \(dispatches.count) dispatches",
      "",
      "Apple HP's image age swings between dispatches (22–82 ms on typing) while its repetitions within one agree, "
        + "so its figures below are the median across dispatches of each dispatch's median, and v2 is judged against "
        + "HP only within a dispatch.",
      "",
      "| Dispatch | Scenes | Display phase ms | v2 vs HP below \(Int(Tier2PhaseParity.thresholdMs)) ms (851-4092) |",
      "| --- | --- | --- | --- |",
    ]
    let rows = dispatches.map { dispatch in
      let groups = Tier2Group.all(dispatch.report.results).map { "\($0.scene) \($0.network)" }
      let parity = dispatch.parity
      return "| \(dispatch.label) | \(groups.joined(separator: ", ")) | \(Tier2Format.number(parity.phaseMs)) | "
        + "\(parity.status) |"
    }
    return (header + rows).joined(separator: "\n")
  }

  private var groups: [Tier2Group] {
    Tier2Group.all(dispatches.flatMap(\.report.results))
  }

  private var acrossTable: String {
    let header = [
      "### Image age by dispatch (median of each dispatch's valid repetitions)",
      "",
      "| Scene | Resolution | Network | System | p50 ms by dispatch | Median | p95 ms by dispatch | Median |",
      "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    let rows = groups.flatMap { group in
      Self.systems.compactMap { system in acrossRow(group, system) }
    }
    return (header + rows).joined(separator: "\n")
  }

  private func acrossRow(_ group: Tier2Group, _ system: BenchSystem) -> String? {
    let p50s = dispatches.map { median($0, group, system) { $0.imageAgeMs?.p50 } }
    let p95s = dispatches.map { median($0, group, system) { $0.imageAgeMs?.p95 } }
    guard p50s.contains(where: { $0 != nil }) else { return nil }

    let cells = [
      group.scene, group.resolution, group.network, system.rawValue, byDispatch(p50s),
      Tier2Format.number(BenchSystemComparison.median(p50s.compactMap(\.self))), byDispatch(p95s),
      Tier2Format.number(BenchSystemComparison.median(p95s.compactMap(\.self))),
    ]
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private var verdictTable: String {
    let labels = dispatches.map(\.label)
    let header = [
      "### v2 against Apple HP within each dispatch",
      "",
      "| Scene | Resolution | Network | System | Metric | " + labels.joined(separator: " | ") + " |",
      "| --- | --- | --- | --- | --- | " + labels.map { _ in "---" }.joined(separator: " | ") + " |",
    ]
    let rows = groups.flatMap { group in
      Self.systems.dropFirst().flatMap { system in
        Self.verdictMetrics.compactMap { metric in verdictRow(group, system, metric) }
      }
    }
    return (header + rows).joined(separator: "\n")
  }

  private func verdictRow(_ group: Tier2Group, _ system: BenchSystem, _ metric: String) -> String? {
    let verdicts = dispatches.map { dispatch in
      dispatch.report.comparisons.first {
        Tier2Group(scene: $0.scene, resolution: $0.resolution, network: $0.network) == group && $0.system == system
          && $0.metric == metric
      }?.verdict.rawValue
    }
    guard verdicts.contains(where: { $0 != nil }) else { return nil }

    let cells = [group.scene, group.resolution, group.network, system.rawValue, metric] + verdicts.map { $0 ?? "–" }
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private func median(
    _ dispatch: Tier2Dispatch, _ group: Tier2Group, _ system: BenchSystem, _ value: (BenchResult) -> Double?
  ) -> Double? {
    let results = dispatch.report.results.filter { group.contains($0) && $0.system == system && $0.valid }
    return BenchSystemComparison.median(results.compactMap(value))
  }

  private func byDispatch(_ values: [Double?]) -> String {
    values.map(Tier2Format.number).joined(separator: ", ")
  }
}
