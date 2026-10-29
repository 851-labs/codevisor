import ScreenSharingBench

enum Tier2Environment {
  static let link = "en0 1000baseT, wired, same switch"

  static func make(_ measurements: [Tier2Measurement]) -> BenchEnvironment? {
    guard let first = measurements.first, let host = machine(first.files.preflights["host-before-preflight.json"])
    else { return nil }

    return BenchEnvironment(
      host: host, viewer: machine(first.files.preflights["viewer-before-preflight.json"]), link: link,
      clock: worstClock(measurements))
  }

  private static func machine(_ preflight: Tier2Preflight?) -> BenchMachine? {
    guard let preflight else { return nil }

    return BenchMachine(
      name: preflight.machine, chip: preflight.chip, os: preflight.os,
      display: preflight.displays.first ?? "unknown", load1AtStart: preflight.load1, thermal: preflight.thermal,
      spotlightBusy: false)
  }

  private static func worstClock(_ measurements: [Tier2Measurement]) -> BenchClockQuality? {
    let qualities = measurements.compactMap { $0.clock?.quality }
    guard !qualities.isEmpty else { return nil }

    return BenchClockQuality(
      epsilonMs: qualities.map(\.epsilonMs).max() ?? 0, driftPpm: qualities.map { abs($0.driftPpm) }.max() ?? 0,
      residualMs: qualities.map(\.residualMs).max() ?? 0)
  }
}
