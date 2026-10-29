import ScreenSharingBench
import ScreenSharingBenchScenes

@MainActor
final class PlayerVersionSource {
  private static let versionCount = BenchBarcode.versions.upperBound + 1

  private let timeline: BenchSceneTimeline
  private(set) var inputEvents = 0
  private var shownInputs = 0

  init(timeline: BenchSceneTimeline) {
    self.timeline = timeline
  }

  func version(atTick tick: Int) -> Int {
    let version = timeline == .inputDriven ? nextInputVersion() : timeline.version(atTick: tick)
    return version % Self.versionCount
  }

  private func nextInputVersion() -> Int {
    shownInputs = min(shownInputs + 1, inputEvents)
    return shownInputs
  }

  func recordInput() {
    inputEvents += 1
  }
}
