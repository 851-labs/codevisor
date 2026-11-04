import CodevisorTestSupport
import Testing
@testable import TranscriptSurface

@Suite("Add to Chat button show timing")
@MainActor
struct TranscriptAddToChatShowTimingTests {
  private static let interval = Duration.milliseconds(500)

  private let clock = TestClock()
  private let shown = TestSignal()

  private func makeTiming() -> TranscriptAddToChatShowTiming {
    TranscriptAddToChatShowTiming(clock: clock, multiClickInterval: { Self.interval })
  }

  @Test(
    "A click that could still become a double or triple click shows once the click window closes",
    arguments: [1, 2])
  func waitsForClickWindow(clickCount: Int) async {
    let timing = makeTiming()

    timing.show(afterClickCount: clickCount, draggedSelection: false) { shown.signal() }
    await clock.waitForSleep(Self.interval)
    clock.advance(by: Self.interval - .milliseconds(1))
    #expect(clock.pendingCount == 1)
    #expect(shown.value == 0)

    clock.advance(by: .milliseconds(1))
    await shown.wait()
    #expect(shown.value == 1)
  }

  @Test("Another click inside the window cancels the pending show")
  func nextClickCancels() async {
    let timing = makeTiming()
    var shownSelections: [String] = []

    timing.show(afterClickCount: 2, draggedSelection: false) { shownSelections.append("word") }
    await clock.waitForSleep(Self.interval)
    timing.cancel()
    timing.show(afterClickCount: 3, draggedSelection: false) { shownSelections.append("paragraph") }

    #expect(clock.pendingCount == 0)
    #expect(shownSelections == ["paragraph"])
  }

  @Test(
    "Drags and triple clicks show right away",
    arguments: [(clickCount: 1, dragged: true), (clickCount: 2, dragged: true), (clickCount: 3, dragged: false)])
  func showsImmediately(gesture: (clickCount: Int, dragged: Bool)) {
    let timing = makeTiming()

    timing.show(afterClickCount: gesture.clickCount, draggedSelection: gesture.dragged) { shown.signal() }

    #expect(shown.value == 1)
    #expect(clock.pendingCount == 0)
  }
}
