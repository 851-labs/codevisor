import AppKit
import ScreenSharingBench
import ScreenSharingBenchScenes

@MainActor
final class PlayerVersionSource {
  private static let versionCount = BenchBarcode.versions.upperBound + 1

  private let timeline: BenchSceneTimeline
  private(set) var inputs: [BenchInputStamp] = []
  private var shownInputs = 0

  init(timeline: BenchSceneTimeline) {
    self.timeline = timeline
  }

  func version(atTick tick: Int) -> Int {
    let version = timeline == .inputDriven ? nextInputVersion() : timeline.version(atTick: tick)
    return version % Self.versionCount
  }

  private func nextInputVersion() -> Int {
    shownInputs = min(shownInputs + 1, inputs.count)
    return shownInputs
  }

  func recordInput(_ event: NSEvent) {
    if let stamp = BenchInputStamp(event, ns: BenchMachClock.nowNs()) { inputs.append(stamp) }
  }
}
