import ScreenSharingBench

struct Tier2InputTable {
  static let m3MarginMs = 8.0

  private let rows: [Tier2InputRow]
  private let floors: Tier2InputFloors

  init(_ measurements: [Tier2Measurement], floors: Tier2InputFloors) {
    let shared = measurements.filter { $0.files.meta.isInput && $0.files.meta.benchSystem != nil }
    let keys = shared.compactMap(Self.key).reduce(into: [Tier2InputRow.Key]()) { keys, key in
      if !keys.contains(key) { keys.append(key) }
    }
    rows = keys.map { key in Tier2InputRow(key: key, measurements: shared.filter { Self.key($0) == key }) }
    self.floors = floors
  }

  var text: String? {
    guard !rows.isEmpty || floors.pooledMs != nil else { return nil }

    let header = [
      "### Input to photon (S7, median of valid repetitions)", "",
      "Space presses and clicks posted on the viewer, each timed to the viewer observer's first frame showing "
        + "another version. Events whose change landed after the next event are unanswered. The C6 floor is the "
        + "same events on a local player on the viewer. M3: p50 at most Apple HP's p50 + \(Int(Self.m3MarginMs)) ms "
        + "(Apple HP on the same network).", "",
      floorLine, "",
      "| Resolution | Network | System | Events | Answered | p50 ms | p95 | max | Keys p50 | Clicks p50 "
        + "| p50 − floor | p95 − floor p95 | p50 − Apple HP p50 | M3 | Valid reps |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    return (header + rows.map(line)).joined(separator: "\n")
  }

  private var floorLine: String {
    guard let floor = floors.pooledMs else { return "C6 floor: not measured" }

    return "C6 floor (pooled): p50 \(Tier2Format.number(floor.p50)), p95 \(Tier2Format.number(floor.p95)), "
      + "max \(Tier2Format.number(floor.max)), n \(floor.count)"
  }

  private func line(_ row: Tier2InputRow) -> String {
    let appleP50 = appleP50(network: row.key.network)
    var cells = row.cells(floors: floors, appleP50: appleP50)
    cells.insert(m3(row, appleP50: appleP50), at: cells.count - 1)
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private func m3(_ row: Tier2InputRow, appleP50: Double?) -> String {
    guard row.key.system != .appleHP else { return "–" }
    guard let p50 = row.p50, let appleP50 else { return "– not measured" }

    return p50 <= appleP50 + Self.m3MarginMs ? "✅ met" : "❌ missed"
  }

  private func appleP50(network: String) -> Double? {
    rows.first { $0.key.system == .appleHP && $0.key.network == network }?.p50
  }

  private static func key(_ measurement: Tier2Measurement) -> Tier2InputRow.Key? {
    let meta = measurement.files.meta
    guard let system = meta.benchSystem else { return nil }

    return Tier2InputRow.Key(resolution: meta.resolutionLabel, network: meta.networkLabel, system: system)
  }
}
