import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCoreMac

private final class ForegroundTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var elapsed: TimeInterval = 0
  var now: TimeInterval { lock.withLock { elapsed } }
  func set(_ elapsed: TimeInterval) { lock.withLock { self.elapsed = elapsed } }
}

@Suite("Computer Use foreground lock")
struct ComputerUseForegroundTests {
  @Test("A competing request fails immediately without running its input")
  func exclusiveAccess() throws {
    let clock = ForegroundTestClock()
    let lock = ComputerUseForegroundLock(now: { clock.now })
    var delivered = false
    try lock.perform(sessionID: "first", pid: 1) {
      do {
        try lock.perform(sessionID: "second", pid: 2) { delivered = true }
        Issue.record("Competing foreground input must return busy")
      } catch {
        #expect(String(describing: error).contains("busy"))
      }
      try lock.check(lock.currentToken, pid: 1)
    }
    #expect(!delivered)
    try lock.perform(sessionID: "second", pid: 2) {
      try lock.withInput(lock.currentToken, pid: 2) { delivered = true }
    }
    #expect(delivered)
    #expect(lock.currentToken == nil)
  }

  @Test("Exceptions release ownership without a manual unlock")
  func exceptionCleanup() throws {
    struct ActionFailure: Error {}
    let lock = ComputerUseForegroundLock()
    #expect(throws: ActionFailure.self) {
      try lock.perform(sessionID: "failed", pid: 1) { throw ActionFailure() }
    }
    #expect(lock.currentToken == nil)
    try lock.perform(sessionID: "next", pid: 2) {
      try lock.check(lock.currentToken, pid: 2)
    }
  }

  @Test("A stalled action expires, cannot inject late input, and cannot unlock its successor")
  func abandonedAction() async throws {
    let clock = ForegroundTestClock()
    let lock = ComputerUseForegroundLock(now: { clock.now })
    let started = TestSignal()
    let resume = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let oldAction = Task.detached {
      defer { finished.signal() }
      // Use the same agent and PID as the successor: neither is sufficient
      // proof of ownership when an old call eventually resumes.
      return try lock.perform(sessionID: "same-agent", pid: 1) {
        started.signal()
        guard resume.wait(timeout: .now() + 5) == .success else {
          throw BridgeError("Test gate was not released")
        }
        var delivered = false
        do {
          try lock.withInput(lock.currentToken, pid: 1) { delivered = true }
        } catch {
          #expect(String(describing: error).contains("expired"))
        }
        // Even a delayed key/button release must not affect the successor
        // while it is using the same app.
        lock.withCleanup(lock.currentToken, pid: 1) { delivered = true }
        return !delivered
      }
    }
    await started.wait()
    clock.set(7.999)
    #expect(throws: BridgeError.self) {
      try lock.perform(sessionID: "same-agent", pid: 1) {
        Issue.record("Ownership must remain exclusive before its deadline")
      }
    }
    clock.set(8)
    var successorInput = false
    let successor = Result {
      try lock.perform(sessionID: "same-agent", pid: 1) {
        resume.signal()
        // This timeout only guards a broken test/deadlock; fake time above
        // drives the actual ownership expiration being tested.
        #expect(finished.wait(timeout: .now() + 5) == .success)
        try lock.withInput(lock.currentToken, pid: 1) { successorInput = true }
      }
    }
    resume.signal()
    let staleInputRejected = try await oldAction.value
    try successor.get()
    #expect(staleInputRejected)
    #expect(successorInput)
  }

  @Test("The deadline cannot be extended by repeated input checks")
  func fixedDeadline() throws {
    let clock = ForegroundTestClock()
    let lock = ComputerUseForegroundLock(now: { clock.now })
    try lock.perform(sessionID: "active", pid: 1) {
      for instant: TimeInterval in [1, 4, 7.999] {
        clock.set(instant)
        try lock.check(lock.currentToken, pid: 1)
      }
      clock.set(8)
      do {
        try lock.check(lock.currentToken, pid: 1)
        Issue.record("Repeated checks must not renew foreground ownership")
      } catch {
        #expect(error is BridgeError)
      }
      try lock.perform(sessionID: "next", pid: 2) {
        try lock.check(lock.currentToken, pid: 2)
      }
    }
  }

  @Test("Human input revokes ownership and returns busy until two seconds of quiet")
  func humanPriority() throws {
    let clock = ForegroundTestClock()
    let lock = ComputerUseForegroundLock(now: { clock.now })
    try lock.perform(sessionID: "active", pid: 1) {
      lock.humanInput()
      #expect(throws: BridgeError.self) { try lock.check(lock.currentToken, pid: 1) }
      clock.set(1.999)
      #expect(throws: BridgeError.self) { try lock.perform(sessionID: "next", pid: 2) {} }
      lock.humanInput()
      clock.set(3.998)
      #expect(throws: BridgeError.self) { try lock.perform(sessionID: "next", pid: 2) {} }
      clock.set(3.999)
      try lock.perform(sessionID: "next", pid: 2) {
        try lock.check(lock.currentToken, pid: 2)
      }
    }
  }

  @Test("Closing the owner releases access immediately without cancelling other sessions")
  func sessionCleanup() throws {
    let lock = ComputerUseForegroundLock()
    try lock.perform(sessionID: "active", pid: 1) {
      lock.cancel(sessionID: "unrelated")
      try lock.check(lock.currentToken, pid: 1)
      lock.cancel(sessionID: "active")
      #expect(throws: BridgeError.self) { try lock.check(lock.currentToken, pid: 1) }
      try lock.perform(sessionID: "next", pid: 2) {
        try lock.check(lock.currentToken, pid: 2)
      }
    }
  }
}
