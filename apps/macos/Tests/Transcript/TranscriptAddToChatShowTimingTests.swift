import CodevisorTestSupport
import Testing
@testable import TranscriptSurface

@Suite("Add to Chat button show timing")
@MainActor
struct TranscriptAddToChatShowTimingTests {
  struct PendingClick: Sendable {
    let clickCount: Int
    let doubleClickInterval: Duration
    let wait: Duration
  }

  private static let defaultDoubleClickInterval = Duration.milliseconds(500)
  private static let cappedWait = Duration.milliseconds(250)

  private let clock = TestClock()
  private let shown = TestSignal()

  private func makeTiming(doubleClickInterval: Duration = defaultDoubleClickInterval) -> TranscriptAddToChatShowTiming {
    TranscriptAddToChatShowTiming(clock: clock, doubleClickInterval: { doubleClickInterval })
  }

  @Test(
    "A click that could still become a double or triple click waits for the shorter of the double-click interval and 250 ms",
    arguments: [
      PendingClick(clickCount: 1, doubleClickInterval: .milliseconds(500), wait: .milliseconds(250)),
      PendingClick(clickCount: 2, doubleClickInterval: .milliseconds(500), wait: .milliseconds(250)),
      PendingClick(clickCount: 2, doubleClickInterval: .milliseconds(200), wait: .milliseconds(200)),
    ])
  func waitsForClickWindow(click: PendingClick) async {
    let timing = makeTiming(doubleClickInterval: click.doubleClickInterval)

    timing.show(afterClickCount: click.clickCount, draggedSelection: false) { shown.signal() }
    await clock.waitForSleep(click.wait)
    clock.advance(by: click.wait - .milliseconds(1))
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
    await clock.waitForSleep(Self.cappedWait)
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
