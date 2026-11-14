import AppKit
import CodevisorTestSupport
import Observation
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite("On-screen reports from a pane view", .timeLimit(.minutes(1)))
struct ScreenSharingOnScreenReporterTests {
  private static let confirmation = ScreenSharingOnScreenReporter.hiddenConfirmation

  private let clock = TestClock()
  private let window = StagedWindow()
  private let log = Log()
  private let reporter: ScreenSharingOnScreenReporter

  init() {
    reporter = ScreenSharingOnScreenReporter(sleep: { [clock] in try await clock.sleep(for: $0) })
  }

  @Test func comingOnScreenIsReportedWithoutWaiting() async {
    show(makeProbe())
    await awaitObserved { log.reports == [true] }

    #expect(clock.requestCount(Self.confirmation) == 0)
  }

  @Test func aHideThatEndsWithinTheConfirmationIsNeverReported() async {
    show(makeProbe())
    await awaitObserved { log.reports == [true] }

    window.shows = false
    await clock.waitForSleep(Self.confirmation)
    window.shows = true
    window.shows = false
    await clock.waitForSleep(Self.confirmation, count: 2)
    clock.advance(by: Self.confirmation)
    await awaitObserved { log.reports.count == 2 }

    #expect(log.reports == [true, false], "the first, brief hide left no trace")
  }

  @Test func aHideIsReportedOnceItHasLastedTheConfirmation() async {
    show(makeProbe())
    await awaitObserved { log.reports == [true] }

    window.shows = false
    await clock.waitForSleep(Self.confirmation)
    clock.advance(by: Self.confirmation - .milliseconds(1))
    #expect(log.reports == [true])
    clock.advance(by: .milliseconds(1))
    await awaitObserved { log.reports == [true, false] }
  }

  @Test func aViewThatWasTornDownIsReportedHiddenAfterItsProbeIsGone() async {
    var probe: ScreenSharingOnScreenProbe? = makeProbe()
    probe.map(show)
    await awaitObserved { log.reports == [true] }

    probe?.retire()
    probe?.removeFromSuperview()
    probe = nil
    await clock.waitForSleep(Self.confirmation)
    clock.advance(by: Self.confirmation)

    await awaitObserved { log.reports == [true, false] }
  }

  private func makeProbe() -> ScreenSharingOnScreenProbe {
    let probe = ScreenSharingOnScreenProbe()
    reporter.follow(probe) { [log] in log.reports.append($0) }
    return probe
  }

  private func show(_ probe: ScreenSharingOnScreenProbe) {
    probe.setFrameSize(NSSize(width: 240, height: 150))
    window.contentView?.addSubview(probe)
  }

  @MainActor
  @Observable
  final class Log {
    var reports: [Bool] = []
  }
}
