import ScreenSharingBench

struct Tier2InputFloors {
  let pooledMs: BenchDistribution?
  private let p50ByNetworkMs: [String: Double]
  private let p95ByNetworkMs: [String: Double]

  init(_ measurements: [Tier2Measurement]) {
    let floors = measurements.filter { $0.files.meta.isLocalInputFloor && $0.invalidReason == nil }
    let byNetwork = Dictionary(grouping: floors) { $0.files.meta.networkLabel }
    p50ByNetworkMs = byNetwork.compactMapValues { runs in
      BenchSystemComparison.median(runs.compactMap { $0.inputToPhoton?.answered?.p50 })
    }
    p95ByNetworkMs = byNetwork.compactMapValues { runs in
      BenchSystemComparison.median(runs.compactMap { $0.inputToPhoton?.answered?.p95 })
    }
    pooledMs = BenchDistribution(floors.flatMap { $0.inputToPhoton?.delaysMs ?? [] })
  }

  func p50(network: String) -> Double? {
    p50ByNetworkMs[network]
  }

  func p95(network: String) -> Double? {
    p95ByNetworkMs[network]
  }
}
