import ScreenSharingBench

struct ObserveSummary: Encodable {
  let clock: String
  let source: String
  let frames: Int
  let versions: Int
  let unreadableFraction: Double
  let callbackDelayMs: BenchDistribution?
  let observerCpuPct: Double?
  let observerPowerMw: Double?
  let output: String?

  init(_ log: BenchObserverLog, output: String?) {
    let versions = log.versions
    clock = log.header.clock
    source = log.header.source
    frames = versions.frames
    self.versions = versions.firstPtsNs.count
    unreadableFraction = versions.unreadableFraction
    callbackDelayMs = BenchDistribution(log.observations.map { Double($0.callbackNs - $0.ptsNs) / 1_000_000 })
    observerCpuPct = log.header.observerCpuPct
    observerPowerMw = log.header.observerPowerMw
    self.output = output
  }
}
