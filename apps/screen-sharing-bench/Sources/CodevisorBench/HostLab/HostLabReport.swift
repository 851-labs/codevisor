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
    guard let run, run.capturedSeconds > 0 else { return nil }

    return run.counters[counter].map { Double($0) / run.capturedSeconds }
  }
}

struct HostLabReport: Encodable {
  let resolution: String
  let seconds: Int
  let results: [HostLabResult]

  var markdown: String {
    let header =
      "| Scene | Variant | All % | host-run % | VTEncoder % | WindowServer % | replayd % | player % | Captures | Tiles | "
      + "Refinements | Converged | Encode p50 ms |"
    let rows = results.map { result in
      let cells = [result.allProcesses?.cpuPct] + HostLabCommand.groups.map { result.cpuPct[$0] }
      let rates = ["captureFrames", "tilesEncoded", "refinementUpdates", "refinementsConverged"].map {
        result.perSecond($0)
      }
      let encode = result.run?.timings["encode"]?.p50Ms
      return "| \(result.scene) | \(result.variant) | "
        + (cells + rates + [encode]).map(Self.number).joined(separator: " | ") + " |"
    }
    let passes = results.map { result in
      let sizes = (result.run?.passes ?? []).map {
        "pass \($0.pass): \($0.count) × \($0.meanBytes) B (p50 \($0.p50Bytes))"
      }
      return "- \(result.scene) \(result.variant): " + (sizes.isEmpty ? "no tiles" : sizes.joined(separator: ", "))
    }
    let title = [
      "## Host lab at \(resolution), \(seconds) s per variant", "",
      "Counts are per second of the variant's capture. Captures, tiles and refinements come from its host metrics.", "",
      header,
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    let sizes = ["", "Encoded tile sizes by refinement pass (0 is the change):", ""] + passes
    return (title + rows + sizes).joined(separator: "\n") + "\n"
  }

  private static func number(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "–"
  }
}
