import ScreenSharingBenchScenes

struct EncodeLabSchedule {
  struct Step {
    let tick: Int
    let version: Int
    let refreshes: Bool
  }

  let timeline: BenchSceneTimeline
  let ticks: Int
  let refreshTick: Int
  private var tick = 0
  private var lastVersion: Int?
  private var refreshed = false

  init(timeline: BenchSceneTimeline, ticks: Int, refreshTick: Int) {
    self.timeline = timeline
    self.ticks = ticks
    self.refreshTick = refreshTick
  }

  mutating func next() -> Step? {
    while tick < ticks {
      defer { tick += 1 }
      let version = timeline.version(atTick: tick)
      guard version != lastVersion else { continue }

      lastVersion = version
      let refreshes = !refreshed && tick >= refreshTick
      refreshed = refreshed || refreshes
      return Step(tick: tick, version: version, refreshes: refreshes)
    }
    return nil
  }
}
