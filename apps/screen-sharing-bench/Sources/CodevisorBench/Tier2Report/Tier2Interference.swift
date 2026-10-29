import ScreenSharingBench

struct Tier2Interference: Encodable {
  static let scene = "video"

  let system: String
  let updatesDeltaPct: Double?
  let hostCpuDeltaPct: Double?
  let bitrateDeltaPct: Double?

  static func make(_ measurements: [Tier2Measurement]) -> [Tier2Interference] {
    [Tier2RunMeta.System.appleHP, .codevisor].compactMap { system in
      let runs = measurements.filter { $0.files.meta.system == system && $0.files.meta.scene == scene }
      let off = runs.filter { !$0.files.meta.hostObserver && $0.invalidReason == nil }
      let resolutions = Set(off.map { $0.files.meta.resolution })
      let on = runs.filter {
        $0.files.meta.hostObserver && $0.invalidReason == nil && resolutions.contains($0.files.meta.resolution)
      }
      guard !off.isEmpty, !on.isEmpty else { return nil }

      return Tier2Interference(system: system.rawValue, observed: on, unobserved: off)
    }
  }

  private init(system: String, observed: [Tier2Measurement], unobserved: [Tier2Measurement]) {
    self.system = system
    updatesDeltaPct = Self.deltaPct(observed, unobserved) { $0.analysis?.updatesPerS }
    hostCpuDeltaPct = Self.deltaPct(observed, unobserved) { $0.hostUsage?.cpuPct?.p50 }
    bitrateDeltaPct = Self.deltaPct(observed, unobserved) { $0.viewerUsage?.receivedMbps?.p50 }
  }

  static func calibration(_ interference: [Tier2Interference]) -> BenchCalibration.ObserverInterference? {
    let updates = interference.compactMap(\.updatesDeltaPct).max { abs($0) < abs($1) }
    let cpu = interference.compactMap(\.hostCpuDeltaPct).max { abs($0) < abs($1) }
    guard let updates, let cpu else { return nil }

    return BenchCalibration.ObserverInterference(fpsDeltaPct: updates, cpuDeltaPct: cpu)
  }

  private static func deltaPct(
    _ observed: [Tier2Measurement], _ unobserved: [Tier2Measurement], _ value: (Tier2Measurement) -> Double?
  ) -> Double? {
    guard let on = BenchSystemComparison.median(observed.compactMap(value)),
      let off = BenchSystemComparison.median(unobserved.compactMap(value)), off != 0
    else { return nil }

    return (on - off) / off * 100
  }
}
