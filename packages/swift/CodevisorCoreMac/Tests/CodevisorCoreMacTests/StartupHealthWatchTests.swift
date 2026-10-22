import Foundation
import Testing
@testable import CodevisorCoreMac

@Suite("StartupHealthWatch")
struct StartupHealthWatchTests {
  @Test("A launchd job gives up after three dead probes in a row; a live or unknown probe does not")
  func deadJobProbes() {
    var watch = makeWatch(attemptLimit: 100)

    #expect(watch.noteJobProbe(false) == JobProbeNote(text: ", launchd job has no process (1/3)", givesUp: false))
    #expect(watch.noteJobProbe(nil) == JobProbeNote(text: ", launchd job state unknown", givesUp: false))
    #expect(watch.noteJobProbe(false) == JobProbeNote(text: ", launchd job has no process (2/3)", givesUp: false))
    #expect(watch.noteJobProbe(true) == JobProbeNote(text: ", launchd job running", givesUp: false))
    #expect(watch.noteJobProbe(false).givesUp == false)
    #expect(watch.noteJobProbe(false).givesUp == false)
    #expect(watch.noteJobProbe(false) == JobProbeNote(text: ", launchd job has no process (3/3)", givesUp: true))
  }

  @Test("Reports every eighth attempt and the last one, which progress can push out")
  func reportCadence() {
    var watch = makeWatch(attemptLimit: 10, progressAttemptLimit: 20)
    var reported: [Int] = []
    while watch.hasAttemptsLeft {
      watch.beginAttempt()
      if watch.attempt == 5 { watch.noteProgress(at: start) }
      if watch.isReportDue { reported.append(watch.attempt) }
    }

    #expect(reported == [8, 16, 20])
    #expect(
      watch.timeoutMessage(logPath: "/log")
        == "Timed out waiting for Codevisor server after 20 attempt(s) (last probe: none). See /log")
  }

  @Test("Progress never shrinks the attempt budget")
  func progressKeepsLargerBudget() {
    var watch = makeWatch(attemptLimit: 30, progressAttemptLimit: 20)
    watch.noteProgress(at: start + .seconds(1))

    #expect(watch.attemptLimit == 30)
    #expect(watch.lastProgressAt == start + .seconds(1))
  }

  private let start = ContinuousClock.now

  private func makeWatch(attemptLimit: Int, progressAttemptLimit: Int = 2400) -> StartupHealthWatch {
    StartupHealthWatch(
      expectedBootId: nil,
      requiresBundledIdentity: false,
      deadline: start + .milliseconds(100),
      lastProgressAt: start,
      stallTimeout: .milliseconds(20),
      attemptLimit: attemptLimit,
      progressAttemptLimit: progressAttemptLimit
    )
  }
}
