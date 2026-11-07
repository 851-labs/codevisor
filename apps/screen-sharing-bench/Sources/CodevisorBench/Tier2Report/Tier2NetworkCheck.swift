import ScreenSharingBench

enum Tier2NetworkCheck {
  struct Spec {
    let delayMs: Double
    let lossEachWay: Double

    var roundTripLossPct: Double {
      100 * (1 - (1 - lossEachWay) * (1 - lossEachWay))
    }
  }

  static let specs = ["N3": Spec(delayMs: 1, lossEachWay: 0.01), "N6": Spec(delayMs: 25, lossEachWay: 0.001)]

  static func describe(_ check: BenchResult.NetworkCheck?) -> String {
    guard let check else { return "–" }
    guard check.replies > 0 else { return "no replies" }

    return "RTT \(Tier2Format.number(check.roundTripMs)) ms, \(Tier2Format.number(check.lossFraction * 100))% lost"
  }

  static func table(_ measurements: [Tier2Measurement]) -> String? {
    let shaped = measurements.filter { $0.files.realizedNetwork != nil }
    let byNetwork = Dictionary(grouping: shaped, by: \.files.meta.networkLabel)
    guard !byNetwork.isEmpty else { return nil }

    let header = [
      "### Network as realized",
      "",
      "Before each shaped run the viewer probes tamale through the shaping (`network-check.json`): the round trip is "
        + "the median of each burst's fastest probe, and a probe is lost when its request or its reply is. The "
        + "unshaped round trip comes from the same runs' clock probes, which the shaping leaves out. The spec's round "
        + "trip is the unshaped one plus twice the delay; dummynet holds a packet about 0.25 ms past a 1 ms delay "
        + "(851-3749), so N3 realizes about 0.5 ms more than that. Keep `specs` in step with `network_apply` in "
        + "scripts/tier2-network.sh.",
      "",
      "| Network | Spec | Unshaped RTT ms | Realized RTT ms | Spec RTT ms | Lost % | Spec lost % | Probes |",
      "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    let rows = byNetwork.keys.sorted().map { network in
      row(network, byNetwork[network, default: []])
    }
    return (header + rows).joined(separator: "\n")
  }

  private static func row(_ network: String, _ measurements: [Tier2Measurement]) -> String {
    let checks = measurements.compactMap(\.files.realizedNetwork)
    let pooled = BenchResult.NetworkCheck(
      probes: checks.map(\.probes).reduce(0, +), replies: checks.map(\.replies).reduce(0, +), roundTripMs: nil)
    let realized = BenchSystemComparison.median(checks.compactMap(\.roundTripMs))
    let unshaped = BenchSystemComparison.median(measurements.compactMap(unshapedRoundTripMs))
    let spec = specs[network]
    let expected = spec.flatMap { spec in unshaped.map { $0 + 2 * spec.delayMs } }
    let cells = [
      network,
      spec.map { "\(Tier2Format.number($0.delayMs)) ms, \(Tier2Format.number($0.lossEachWay * 100))% each way" }
        ?? "–",
      Tier2Format.number(unshaped), Tier2Format.number(realized), Tier2Format.number(expected),
      Tier2Format.number(pooled.probes > 0 ? pooled.lossFraction * 100 : nil),
      Tier2Format.number(spec?.roundTripLossPct), "\(pooled.probes)",
    ]
    return "| " + cells.joined(separator: " | ") + " |"
  }

  private static func unshapedRoundTripMs(_ measurement: Tier2Measurement) -> Double? {
    let fastest = measurement.files.clockBursts.compactMap { $0.map(\.roundTripNs).min() }
    return BenchSystemComparison.median(fastest.map { Double($0) / 1_000_000 })
  }
}
