import ScreenSharingBench

struct Tier2PhaseParity {
  struct Row {
    let group: Tier2Group
    let system: BenchSystem
    let p50Ms: Double?
    let appleP50Ms: Double?
    let p95Ms: Double?
    let appleP95Ms: Double?

    var p50OverAppleMs: Double? { difference(p50Ms, appleP50Ms) }
    var p95OverAppleMs: Double? { difference(p95Ms, appleP95Ms) }

    var met: Bool? {
      guard let p50OverAppleMs, let p95OverAppleMs else { return nil }

      return p50OverAppleMs <= Tier2PhaseParity.p50MarginMs && p95OverAppleMs <= Tier2PhaseParity.p95MarginMs
    }

    private func difference(_ value: Double?, _ apple: Double?) -> Double? {
      guard let value, let apple else { return nil }

      return value - apple
    }
  }

  static let thresholdMs = 12.0
  static let scenes = ["window-drag", "scroll", "typing"]
  static let network = "N0"
  static let p50MarginMs = Tier2InputTable.m3MarginMs
  static let p95MarginMs = 17.0
  static let systems: [BenchSystem] = [.codevisorV2, .codevisorV2VCP]

  let phaseMs: Double?
  let runPhasesMs: [Double]
  let rows: [Row]

  init(results: [BenchResult]) {
    runPhasesMs = results.compactMap(\.displayPhaseMs)
    phaseMs = Tier2DisplayPhase.meanMs(runPhasesMs)
    let valid = results.filter(\.valid)
    let groups = Tier2Group.all(valid).filter { Self.scenes.contains($0.scene) && $0.network == Self.network }
    rows = groups.flatMap { group in
      let inGroup = valid.filter(group.contains)
      let apple = inGroup.filter { $0.system == .appleHP }
      return Self.systems.compactMap { system -> Row? in
        let ours = inGroup.filter { $0.system == system }
        guard !ours.isEmpty, !apple.isEmpty else { return nil }

        return Row(
          group: group, system: system, p50Ms: Self.median(ours) { $0.imageAgeMs?.p50 },
          appleP50Ms: Self.median(apple) { $0.imageAgeMs?.p50 }, p95Ms: Self.median(ours) { $0.imageAgeMs?.p95 },
          appleP95Ms: Self.median(apple) { $0.imageAgeMs?.p95 })
      }
    }
  }

  var isBelowThreshold: Bool {
    phaseMs.map { $0 < Self.thresholdMs } ?? false
  }

  var regressions: [Row] {
    isBelowThreshold ? rows.filter { $0.met == false } : []
  }

  var headline: String? {
    guard let phaseMs else { return nil }

    let phase = "Display phase \(Tier2Format.number(phaseMs)) ms"
    guard isBelowThreshold else {
      return "\(phase) (host refresh → viewer refresh): at or above \(Int(Self.thresholdMs)) ms, so this dispatch "
        + "doesn't check v2's image-age parity below it (851-4092)."
    }
    if !regressions.isEmpty {
      let misses = regressions.map { row in
        "\(row.system.rawValue) on \(row.group.scene) (p50 \(signed(row.p50OverAppleMs)), "
          + "p95 \(signed(row.p95OverAppleMs)) ms against Apple HP)"
      }
      return "**⚠️ Regression (851-4092): at display phase \(Tier2Format.number(phaseMs)) ms, "
        + "\(misses.joined(separator: "; ")) misses M3.**"
    }
    guard rows.contains(where: { $0.met != nil }) else {
      return "**\(phase), below \(Int(Self.thresholdMs)) ms**, but this dispatch has no valid v2 and Apple HP "
        + "runs of \(Self.scenes.joined(separator: ", ")) at \(Self.network) to compare (851-4092)."
    }
    let scenes = Set(rows.filter { $0.met == true }.map(\.group.scene)).sorted().joined(separator: ", ")
    return "**\(phase), below \(Int(Self.thresholdMs)) ms: v2 is within M3 of Apple HP on \(scenes) (851-4092).**"
  }

  var status: String {
    guard phaseMs != nil else { return "– no phase" }
    guard isBelowThreshold else { return "not checked (at or above \(Int(Self.thresholdMs)) ms)" }
    if !regressions.isEmpty {
      return "❌ regression: " + regressions.map { "\($0.system.rawValue) on \($0.group.scene)" }.joined(separator: ", ")
    }
    return rows.contains { $0.met != nil } ? "✅ within M3" : "– nothing to compare"
  }

  var text: String? {
    guard phaseMs != nil || !rows.isEmpty else { return nil }

    let spread = runPhasesMs.min().flatMap { low in runPhasesMs.max().map { (low, $0) } }
    let header = [
      "### Display phase and image-age parity (851-4092)",
      "",
      "The display phase is the time from a host refresh to the next viewer refresh: the circular mean of each "
        + "observer's frame timestamps modulo 1/60 s, on the viewer's clock, viewer minus host. The two Macs' "
        + "display clocks set it, so it holds within a dispatch and drifts between dispatches. This dispatch: "
        + (phaseMs.map { "\(Tier2Format.number($0)) ms" } ?? "no steady phase")
        + (spread.map { " (runs \(Tier2Format.number($0.0))–\(Tier2Format.number($0.1)) ms)" } ?? "") + ".",
      "",
      "M3 against Apple HP in the same dispatch: p50 at most HP + \(Int(Self.p50MarginMs)) ms and p95 at most HP + "
        + "\(Int(Self.p95MarginMs)) ms, median of valid repetitions, at \(Self.network). A miss is a regression "
        + "when the phase is below \(Int(Self.thresholdMs)) ms.",
      "",
      "| Scene | System | p50 ms | HP p50 | p50 − HP | p95 ms | HP p95 | p95 − HP | M3 |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    return (header + rows.map(row)).joined(separator: "\n")
  }

  private func row(_ row: Row) -> String {
    let result =
      switch row.met {
      case true?: "✅ met"
      case false?: isBelowThreshold ? "❌ regression" : "❌ missed"
      case nil: "– not measured"
      }
    let cells = [
      row.group.scene, row.system.rawValue, Tier2Format.number(row.p50Ms), Tier2Format.number(row.appleP50Ms),
      signed(row.p50OverAppleMs), Tier2Format.number(row.p95Ms), Tier2Format.number(row.appleP95Ms),
      signed(row.p95OverAppleMs), result,
    ]
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private func signed(_ value: Double?) -> String {
    guard let value else { return "–" }

    return (value >= 0 ? "+" : "") + Tier2Format.number(value)
  }

  private static func median(_ results: [BenchResult], _ value: (BenchResult) -> Double?) -> Double? {
    BenchSystemComparison.median(results.compactMap(value))
  }
}
