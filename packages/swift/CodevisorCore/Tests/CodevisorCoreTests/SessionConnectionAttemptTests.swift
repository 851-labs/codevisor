import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCore

@MainActor
struct SessionConnectionAttemptTests {
  @Test func aCancelledViewWaiterDoesNotCancelOrDuplicateTheConnection() async {
    let owner = SessionConnectionAttempt()
    let entered = TestSignal(), release = TestSignal()
    var connections = 0
    var connected = false
    owner.start(
      harnessName: "Agent",
      connect: {
        connections += 1
        entered.signal()
        await release.wait()
      },
      onEvent: { if case .connected = $0 { connected = true } })
    await entered.wait()
    let viewWaiter = Task { await owner.waitForCompletion() }
    viewWaiter.cancel()
    owner.start(
      harnessName: "Duplicate", connect: { connections += 1 }, onEvent: { _ in })
    #expect(owner.isRunning)
    release.signal()
    await viewWaiter.value
    #expect(connections == 1)
    #expect(connected)
    #expect(!owner.isRunning)
  }

  @Test func supersessionWaitsForCancellationToSettleBeforeAReplacementStarts() async {
    let owner = SessionConnectionAttempt()
    let entered = TestSignal(), cancelled = TestSignal(), release = TestSignal()
    var cancellations = 0
    var failures = 0
    var connections = 0
    owner.start(
      harnessName: "Agent",
      connect: {
        await withTaskCancellationHandler {
          entered.signal()
          await release.wait()
        } onCancel: {
          cancelled.signal()
        }
        try Task.checkCancellation()
      },
      onEvent: {
        if case .cancelled = $0 { cancellations += 1 }
        if case .failed = $0 { failures += 1 }
      })
    await entered.wait()
    let supersede = Task { await owner.cancelAndWait() }
    await cancelled.wait()
    #expect(owner.isRunning)
    release.signal()
    await supersede.value
    #expect(cancellations == 1)
    #expect(failures == 0)
    #expect(!owner.isRunning)
    owner.start(
      harnessName: "Replacement", connect: { connections += 1 }, onEvent: { _ in })
    await owner.waitForCompletion()
    #expect(connections == 1)
    #expect(!owner.isRunning)
  }

  @Test func anOrdinaryFailureReleasesTheAttemptForRetry() async {
    let owner = SessionConnectionAttempt()
    var failures = 0
    var connections = 0
    owner.start(
      harnessName: "Agent", connect: { throw URLError(.badURL) },
      onEvent: { if case .failed = $0 { failures += 1 } })
    await owner.waitForCompletion()
    #expect(failures == 1)
    #expect(!owner.isRunning)
    owner.start(
      harnessName: "Retry", connect: { connections += 1 }, onEvent: { _ in })
    await owner.waitForCompletion()
    #expect(connections == 1)
    #expect(!owner.isRunning)
  }
}
