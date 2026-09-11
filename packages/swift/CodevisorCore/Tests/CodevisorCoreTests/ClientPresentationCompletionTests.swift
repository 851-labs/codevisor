import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCore

@MainActor
struct ClientPresentationCompletionTests {
  @Test("Dismissal waits for its own native callback and cancels its deadline")
  func acknowledgement() async throws {
    let clock = TestClock()
    let completion = ClientPresentationCompletion { try await clock.sleep(for: .seconds(8)) }
    let started = TestSignal()
    var finished = false
    let task = Task {
      try await completion.dismiss("new_chat") { started.signal() }
      finished = true
    }
    await started.wait()
    await clock.waitForSleep(.seconds(8))
    completion.complete("settings")
    #expect(!finished)
    completion.complete("new_chat")
    try await task.value
    #expect(finished)
    #expect(clock.pendingCount == 0)
  }

  @Test("Timeout and cancellation release pending dismissal waits")
  func interrupted() async {
    for cancel in [false, true] {
      let clock = TestClock()
      let completion = ClientPresentationCompletion { try await clock.sleep(for: .seconds(8)) }
      let task = Task { try await completion.dismiss("settings") {} }
      await clock.waitForSleep(.seconds(8))
      if cancel { task.cancel() } else { clock.advance(by: .seconds(8)) }
      switch await task.result {
      case .success: Issue.record("An unacknowledged dismissal must fail")
      case .failure(let error):
        #expect(cancel ? error is CancellationError : error is ClientControlError)
      }
      completion.complete("settings")
      #expect(clock.pendingCount == 0)
    }
  }
}
