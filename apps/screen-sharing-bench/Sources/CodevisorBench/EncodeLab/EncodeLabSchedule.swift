import ScreenSharingBenchScenes

struct EncodeLabSchedule {
  struct Step {
    let tick: Int
    let version: Int
    let refreshes: Bool
    let repeats: Bool
  }

  static let refineGapTicks = 2

  let timeline: BenchSceneTimeline
  let ticks: Int
  let refreshTick: Int
  let refinements: Int
  private var tick = 0
  private var lastVersion: Int?
  private var lastStepTick = 0
  private var refinementsLeft = 0
  private var refreshed = false

  init(timeline: BenchSceneTimeline, ticks: Int, refreshTick: Int, refinements: Int = 0) {
    self.timeline = timeline
    self.ticks = ticks
    self.refreshTick = refreshTick
    self.refinements = refinements
  }

  mutating func next() -> Step? {
    while tick < ticks {
      defer { tick += 1 }
      let version = timeline.version(atTick: tick)
      if version != lastVersion { return change(to: version) }
      guard refinementsLeft > 0, tick - lastStepTick >= Self.refineGapTicks else { continue }

      refinementsLeft -= 1
      lastStepTick = tick
      return Step(tick: tick, version: version, refreshes: false, repeats: true)
    }
    return nil
  }

  private mutating func change(to version: Int) -> Step {
    lastVersion = version
    lastStepTick = tick
    refinementsLeft = refinements
    let refreshes = !refreshed && tick >= refreshTick
    refreshed = refreshed || refreshes
    return Step(tick: tick, version: version, refreshes: refreshes, repeats: false)
  }
}
