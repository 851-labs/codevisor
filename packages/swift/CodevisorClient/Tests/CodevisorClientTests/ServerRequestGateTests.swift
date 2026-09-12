import Foundation
import Testing
import CodevisorTestSupport
import CodevisorProtocol

@testable import CodevisorClient

@Suite("Server request gate")
struct ServerRequestGateTests {
  @Test("Requests wait until the machine is ready")
  func waitsForReady() async throws {
    let waiting = TestSignal()
    let gate = ServerRequestGate(onWait: { waiting.signal() })
    let completion = CompletionFlag()
    gate.beginWaiting(for: "local")

    let request = Task {
      try await gate.waitUntilReady(for: "local")
      await completion.finish()
    }
    await waiting.wait()
    #expect(await completion.value == false)

    gate.markReady(for: "local")
    try await request.value
    #expect(await completion.value == true)
  }

  @Test("A failed startup releases requests with the startup error")
  func failureReleasesWaiters() async {
    let waiting = TestSignal()
    let gate = ServerRequestGate(onWait: { waiting.signal() })
    gate.beginWaiting(for: "remote")

    let request = Task {
      try await gate.waitUntilReady(for: "remote")
    }
    await waiting.wait()
    gate.markFailed(for: "remote", message: "Server did not start")

    await #expect(throws: ServerRequestGateError.self) {
      try await request.value
    }
  }

  @Test("Machines without an active lifecycle wait pass through")
  func readyByDefault() async throws {
    let gate = ServerRequestGate()
    try await gate.waitUntilReady(for: "unmanaged")
  }

  @Test("An already-ready machine cancels its continuous-clock deadline")
  func readyCancelsContinuousDeadline() async throws {
    let gate = ServerRequestGate()
    try await gate.waitUntilReady(for: "unmanaged", timeout: .seconds(30))
  }

  @Test("A readiness wait times out instead of hanging forever")
  func timeoutReleasesWaiter() async {
    let clock = TestClock()
    let gate = ServerRequestGate(clock: clock)
    gate.beginWaiting(for: "stuck")
    let request = Task { try await gate.waitUntilReady(for: "stuck", timeout: .seconds(30)) }
    await clock.waitForSleep(.seconds(30))
    clock.advance(by: .seconds(30))
    await #expect(throws: ServerRequestGateError.self) { try await request.value }
    #expect(clock.pendingCount == 0)
  }

  @Test("Readiness and cancellation release the pending deadline", arguments: [false, true])
  func releasesDeadline(cancelled: Bool) async throws {
    let clock = TestClock()
    let waiting = TestSignal()
    let gate = ServerRequestGate(clock: clock, onWait: { waiting.signal() })
    gate.beginWaiting(for: "local")
    let request = Task { try await gate.waitUntilReady(for: "local", timeout: .seconds(30)) }
    defer { request.cancel() }
    await waiting.wait()
    await clock.waitForSleep(.seconds(30))
    #expect(clock.pendingCount == 1)

    if cancelled {
      request.cancel()
      await #expect(throws: CancellationError.self) { try await request.value }
    } else {
      gate.markReady(for: "local")
      try await request.value
    }
    #expect(clock.pendingCount == 0)
  }
}

private actor CompletionFlag {
  private(set) var value = false

  func finish() {
    value = true
  }
}
