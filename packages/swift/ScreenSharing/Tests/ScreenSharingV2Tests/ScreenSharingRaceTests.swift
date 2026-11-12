import CodevisorTestSupport
import Foundation
import ScreenSharingV2
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingRaceTests {
  @Test func theDeadlineWinsEvenWhenTheWorkIgnoresCancellation() async throws {
    let stuck = TestSignal()
    let deadline = TestSignal()
    let race = Task { @MainActor in
      try await ScreenSharingRace.value(of: { await stuck.wait() }, before: { await deadline.wait() })
    }
    deadline.signal()
    let value: Void? = try await race.value
    #expect(value == nil)
    stuck.signal()
  }

  @Test func workThatFinishesFirstIsReturnedAndKeepsRunningWhenLateWorkIsKept() async throws {
    let deadline = TestSignal()
    let value = try await ScreenSharingRace.value(
      of: { 42 }, before: { await deadline.cancellableWait() }, cancellingLateWork: false)
    #expect(value == 42)
  }
}
