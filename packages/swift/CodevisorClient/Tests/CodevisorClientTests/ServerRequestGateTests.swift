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

  @Test("A connection loss is only reported for a machine that's connected")
  func lossIsReportedOnlyWhileConnected() {
    let gate = ServerRequestGate()
    let reported = ReportedMachines()
    gate.onConnectionLost { reported.record($0) }
    gate.beginWaiting(for: "reconnecting")
    gate.markFailed(for: "offline", message: "Offline")

    for machine in ["connected", "reconnecting", "offline"] { gate.reportConnectionLost(for: machine) }
    gate.reportConnectionLost(for: "connected")

    #expect(reported.machineIds == ["connected"])
  }

  @Test("Requests after a reported loss wait for the machine to reconnect instead of failing straight away")
  func reportedLossHoldsRequests() async throws {
    let waiting = TestSignal()
    let gate = ServerRequestGate(onWait: { waiting.signal() })
    gate.onConnectionLost { _ in }

    gate.reportConnectionLost(for: "remote")
    let request = Task { try await gate.waitUntilConnected(for: "remote") }
    await waiting.wait()
    gate.markReady(for: "remote")

    try await request.value
  }

  @Test("Waiting for a connection lasts through a failed attempt and ends once the machine is ready")
  func connectionWaitOutlastsFailure() async throws {
    let waiting = TestSignal()
    let gate = ServerRequestGate(onWait: { waiting.signal() })
    gate.beginWaiting(for: "remote")
    let abandoned = Task { try await gate.waitUntilConnected(for: "remote") }
    let kept = Task { try await gate.waitUntilConnected(for: "remote") }
    await waiting.wait(for: 2)

    gate.markFailed(for: "remote", message: "Offline")
    abandoned.cancel()
    await #expect(throws: CancellationError.self) { try await abandoned.value }

    gate.markReady(for: "remote")
    try await kept.value
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

private final class ReportedMachines: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  var machineIds: [String] { lock.withLock { recorded } }

  func record(_ machineId: String) {
    lock.withLock { recorded.append(machineId) }
  }
}
