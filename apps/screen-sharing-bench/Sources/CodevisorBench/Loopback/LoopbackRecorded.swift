import ScreenSharingBench

protocol LoopbackRecorded {
  var system: BenchSystem { get }
  var startNs: Int64 { get }
  var produced: [BenchVersionEvent] { get }
  var barcodes: [Int64: Int?] { get }
  var timingFrames: [BenchTimingFrame] { get }
  var qualityLevel: Int { get }
  var drops: BenchResult.Drops { get }
  var codecErrors: Int { get }
  var codecFailure: String? { get }
  var media: BenchMediaCounters? { get }

  func frames(arrivals: BenchFrameArrivals, clockOffsetNs: Int64) -> [BenchFrameTimestamps]
  func bypassedTheRelay(_ relay: BenchRelayReport) -> Bool
}

extension LoopbackRecorded {
  func unreadableFraction(of produced: [BenchVersionEvent]) -> Double {
    let checked = produced.compactMap { event in barcodes[event.ns].map { $0 == event.version } }
    guard !checked.isEmpty else { return 0 }

    return Double(checked.count { !$0 }) / Double(checked.count)
  }
}
