struct Tier2RunTable {
  private let measurements: [Tier2Measurement]

  init(_ measurements: [Tier2Measurement]) {
    self.measurements = measurements
  }

  var text: String {
    let header = [
      "| # | Scene | Resolution | System | Rep | Host observer | Host display during run | ε ms | Residual ms | Max load1 "
        + "| CI | Valid |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    return "### Runs\n\n" + (header + measurements.map(row)).joined(separator: "\n")
  }

  private func row(_ measurement: Tier2Measurement) -> String {
    let meta = measurement.files.meta
    let quality = measurement.clock?.quality
    let cells: [String] = [
      "\(meta.index)", meta.scene, meta.resolution ?? Tier2Result.defaultResolution, meta.system.rawValue,
      "\(meta.repetition)", meta.hostObserver ? "on" : "off",
      measurement.files.hostDisplayDuringRun ?? "–",
      Tier2Format.number(quality?.epsilonMs), Tier2Format.number(quality?.residualMs),
      Tier2Format.number(measurement.files.highestLoad), measurement.files.ciBusy ? "busy" : "idle",
      measurement.invalidReason ?? "yes",
    ]
    return "| " + cells.joined(separator: " | ") + " |"
  }
}
