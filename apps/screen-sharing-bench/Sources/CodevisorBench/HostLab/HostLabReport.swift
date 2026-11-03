import ScreenSharing

struct HostLabResult: Encodable {
  let scene: String
  let variant: String
  let exitStatus: Int32
  let cpuPct: [String: Double]
  let allProcesses: ProcessTotals?
  let run: HostRunResult?
  let seconds: Int

  func perSecond(_ counter: String) -> Double? {
    run?.counters[counter].map { Double($0) / Double(seconds) }
  }
}

struct HostLabReport: Encodable {
  let resolution: String
  let seconds: Int
  let results: [HostLabResult]

  var markdown: String {
    let header =
      "| Scene | Variant | All % | host-run % | VTEncoder % | WindowServer % | replayd % | player % | Captures | Tiles | "
      + "Refinements | Encode p50 ms |"
    let rows = results.map { result in
      let cells = [result.allProcesses?.cpuPct] + HostLabCommand.groups.map { result.cpuPct[$0] }
      let rates = ["captureFrames", "tilesEncoded", "refinementUpdates"].map { result.perSecond($0) }
      let encode = result.run?.timings["encode"]?.p50Ms
      return "| \(result.scene) | \(result.variant) | "
        + (cells + rates + [encode]).map(Self.number).joined(separator: " | ") + " |"
    }
    return
      ([
        "## Host lab at \(resolution), \(seconds) s per variant", "",
        "Counts are per second. Captures, tiles and refinements come from the variant's host metrics.", "", header,
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
      ] + rows).joined(separator: "\n") + "\n"
  }

  private static func number(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "–"
  }
}
