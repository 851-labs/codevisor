import ScreenSharingBenchScenes
import Testing

struct BenchSceneTimelineTests {
  private static let second = BenchSceneTimeline.ticksPerSecond

  @Test(arguments: [
    (BenchScene.idleCursor, 0, 4),
    (.typing, 0, 10),
    (.typing, 15 * second, 30),
    (.typing, 20 * second, 10),
    (.scroll, 0, 60),
    (.windowDrag, 0, 60),
    (.video, 0, 60),
    (.testCards, 0, 0),
    (.testCards, 3 * second - 1, 1),
    (.input, 0, 0),
  ])
  func scenesChangeAtTheirDesignedRate(scene: BenchScene, from tick: Int, versionsInTheNextSecond: Int) {
    let timeline = scene.timeline

    let produced = timeline.version(atTick: tick + Self.second) - timeline.version(atTick: tick)

    #expect(produced == versionsInTheNextSecond)
  }
}
