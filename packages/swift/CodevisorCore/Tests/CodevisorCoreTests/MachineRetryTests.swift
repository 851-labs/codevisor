import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Machine retry")
struct MachineRetryTests {
  private static let machineId = CodevisorMachine.local.id

  @Test("Retries back off from one second, doubling up to thirty, each spread by a fifth either way")
  func backoffSchedule() {
    let policy = RetryPolicy()

    let steady = (1...7).map { policy.delay(afterFailures: $0, roll: 0) }
    #expect(steady == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
    #expect(policy.delay(afterFailures: 3, roll: -1) == .milliseconds(3200))
    #expect(policy.delay(afterFailures: 3, roll: 1) == .milliseconds(4800))
  }

  @Test("A retry waits out its backoff, or goes at once when the machine reconnects")
  func reconnectEndsTheWait() async {
    let clock = TestClock()
    let machines = makeMachines()
    let retry = MachineRetry(
      machineId: Self.machineId, machines: machines, policy: RetryPolicy(clock: clock, jitter: 0))

    let waited = Task { await retry.wait(afterFailures: 1) }
    await clock.waitForSleep(.seconds(1))
    clock.advance(by: .seconds(1))
    #expect(await waited.value)

    let woken = Task { await retry.wait(afterFailures: 4) }
    await clock.waitForSleep(.seconds(8))
    machines.markReady(for: Self.machineId)
    #expect(await woken.value)
  }

  @Test("A retry whose view went away stops waiting")
  func cancelledRetryStops() async {
    let clock = TestClock()
    let retry = MachineRetry(
      machineId: Self.machineId, machines: makeMachines(), policy: RetryPolicy(clock: clock, jitter: 0))

    let waiting = Task { await retry.wait(afterFailures: 1) }
    await clock.waitForSleep(.seconds(1))
    waiting.cancel()

    #expect(await waiting.value == false)
  }

  private func makeMachines() -> MachineController {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    return MachineController(store: InMemoryStore(), projectList: ProjectListModel(), clientFactory: { _ in fake })
  }
}
