import CodevisorTestSupport
import Darwin
import Foundation
import ScreenSharing
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingCaptureStallRecoveryTests {
  @MainActor final class Host {
    enum Step: Equatable { case restartCapture, restartDaemon }
    var delivering: Bool
    var restartDelivers = false
    var restartThrows = false
    var daemonFixes = true
    var daemonRunning = true
    var daemonRestartedAt: TimeInterval?
    var callbacks = 0
    var time: TimeInterval = 1000
    var steps: [Step] = []
    var stalls = 0
    private var daemonRestarted = false

    init(delivering: Bool) { self.delivering = delivering }

    var recovery: ScreenSharingCaptureStallRecovery {
      ScreenSharingCaptureStallRecovery(
        callbacks: { self.callbacks },
        restartCapture: {
          self.steps.append(.restartCapture)
          if self.restartThrows { throw CocoaError(.featureUnsupported) }
          self.delivering = self.restartDelivers || (self.daemonRestarted && self.daemonFixes)
        },
        restartDaemon: {
          guard self.daemonRunning else { return false }
          self.steps.append(.restartDaemon)
          self.daemonRestarted = true
          self.daemonRestartedAt = self.time
          return true
        },
        lastDaemonRestart: { self.daemonRestartedAt }, now: { self.time },
        sleep: { duration in
          try Task.checkCancellation()
          self.time += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
          if self.delivering { self.callbacks += 1 }
        },
        onStalled: { self.stalls += 1 })
    }
  }

  @Test func aDeliveringCaptureIsLeftAloneAndReplaydIsNeverTouched() async throws {
    let host = Host(delivering: true)
    #expect(try await host.recovery.run(baseline: 0) == .healthy)
    #expect(host.steps.isEmpty && host.stalls == 0)
    #expect(host.time - 1000 == 0.25)
  }

  @Test func silenceShorterThanTheGraceIsNotAStall() async throws {
    let host = Host(delivering: false)
    let recovery = host.recovery
    var polls = 0
    var patched = recovery
    patched.sleep = { duration in
      try await recovery.sleep(duration)
      polls += 1
      if polls == 11 { host.callbacks += 1 }
    }
    #expect(try await patched.run(baseline: 0) == .healthy)
    #expect(host.steps.isEmpty && host.stalls == 0)
  }

  @Test func aRestartedCaptureThatDeliversNeedsNoDaemonRestart() async throws {
    let host = Host(delivering: false)
    host.restartDelivers = true
    #expect(try await host.recovery.run(baseline: 0) == .recovered(restartedDaemon: false))
    #expect(host.steps == [.restartCapture])
    #expect(host.stalls == 1)
    #expect(host.time - 1000 == 3.25)
  }

  @Test func aStuckDaemonIsRestartedAndTheCaptureWithIt() async throws {
    let host = Host(delivering: false)
    #expect(try await host.recovery.run(baseline: 0) == .recovered(restartedDaemon: true))
    #expect(host.steps == [.restartCapture, .restartDaemon, .restartCapture])
    #expect(host.stalls == 1)
    #expect(host.time - 1000 == 7.25)
  }

  @Test func aCaptureThatFailsToRestartGoesStraightToTheDaemon() async throws {
    let host = Host(delivering: false)
    host.restartThrows = true
    #expect(try await host.recovery.run(baseline: 0) == .failed)
    #expect(host.steps == [.restartCapture, .restartDaemon, .restartCapture])
  }

  @Test func replaydIsRestartedAtMostOncePerIntervalAcrossSessions() async throws {
    let first = Host(delivering: false)
    #expect(try await first.recovery.run(baseline: 0) == .recovered(restartedDaemon: true))
    let restartedAt = try #require(first.daemonRestartedAt)

    let soon = Host(delivering: false)
    soon.daemonRestartedAt = restartedAt
    soon.time = restartedAt + ScreenSharingCaptureStallRecovery.daemonRestartInterval - 60
    #expect(try await soon.recovery.run(baseline: 0) == .failed)
    #expect(soon.steps == [.restartCapture])

    let later = Host(delivering: false)
    later.daemonRestartedAt = restartedAt
    later.time = restartedAt + ScreenSharingCaptureStallRecovery.daemonRestartInterval
    #expect(try await later.recovery.run(baseline: 0) == .recovered(restartedDaemon: true))
  }

  @Test func withNoDaemonToRestartTheRecoveryFails() async throws {
    let host = Host(delivering: false)
    host.daemonRunning = false
    #expect(try await host.recovery.run(baseline: 0) == .failed)
    #expect(host.steps == [.restartCapture])
  }

  @Test func aFreshDaemonThatDoesNotHelpIsReportedAsFailure() async throws {
    let host = Host(delivering: false)
    host.daemonFixes = false
    #expect(try await host.recovery.run(baseline: 0) == .failed)
    #expect(host.steps == [.restartCapture, .restartDaemon, .restartCapture])
  }

  @Test func callbacksBeforeTheStartDoNotCountAsDelivery() async throws {
    let host = Host(delivering: false)
    host.callbacks = 500
    host.restartDelivers = true
    #expect(try await host.recovery.run(baseline: 500) == .recovered(restartedDaemon: false))
  }

  @Test func cancellationStopsTheRecoveryBeforeItKillsAnything() async throws {
    let host = Host(delivering: false)
    var recovery = host.recovery
    recovery.onStalled = { withUnsafeCurrentTask { $0?.cancel() } }
    let run = Task { try await recovery.run(baseline: 0) }
    await #expect(throws: CancellationError.self) { try await run.value }
    #expect(!host.steps.contains(.restartDaemon))
  }

  @Test func theDaemonLookupFindsThisUsersProcessByName() throws {
    let name = try #require(ScreenSharingCaptureDaemon.processName(getpid()))
    #expect(ScreenSharingCaptureDaemon.processes(named: name).contains(getpid()))
    #expect((ScreenSharingCaptureDaemon.descriptorCount(getpid()) ?? 0) > 0)
    #expect(ScreenSharingCaptureDaemon.processes(named: "no-such-process-\(UUID().uuidString.prefix(8))").isEmpty)
  }

  @Test func theLiveRecoveryCanCountAnotherStreamsCallbacks() {
    var count = 7
    let recovery = ScreenSharingCaptureStallRecovery.live(
      metrics: ScreenSharingMetrics(), callbacks: { count }, restartCapture: {}, log: { _ in }, onStalled: {})
    #expect(recovery.callbacks() == 7)
    count = 9
    #expect(recovery.callbacks() == 9)
    let metrics = ScreenSharingMetrics()
    metrics.increment("capturedFrames")
    let fromMetrics = ScreenSharingCaptureStallRecovery.live(
      metrics: metrics, restartCapture: {}, log: { _ in }, onStalled: {})
    #expect(fromMetrics.callbacks() == 1)
  }

  @Test func activityCountsCallbacksAndDeliveredFrames() {
    #expect(ScreenSharingCaptureStallRecovery.activity([:]) == 0)
    #expect(ScreenSharingCaptureStallRecovery.activity(["capturedFrames": 2]) == 2)
    #expect(ScreenSharingCaptureStallRecovery.activity(["capturedFrames": 2, "unrelated": 7]) == 2)
  }
}

@MainActor
struct ScreenSharingCaptureStartWatchdogTests {
  @MainActor final class Start {
    private var continuations: [CheckedContinuation<Void, any Error>] = []
    private(set) var calls = 0
    private(set) var retries: [Bool] = []
    let called = TestSignal()
    var completesAtOnceFromCall: Int?

    func run(retry: Bool) async throws {
      calls += 1
      retries.append(retry)
      called.signal()
      if let first = completesAtOnceFromCall, calls >= first { return }
      try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func finish(throwing error: (any Error)? = nil) {
      guard !continuations.isEmpty else { return }
      let continuation = continuations.removeFirst()
      if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
  }

  @MainActor final class Harness {
    let clock = TestClock()
    let start = Start()
    var restarts = 0
    var stalls = 0
    let stalled = TestSignal()
    var lastRestart: TimeInterval?
    var onRestart: (Start) -> Void = { $0.finish(throwing: CocoaError(.featureUnsupported)) }

    var recovery: ScreenSharingCaptureStallRecovery {
      ScreenSharingCaptureStallRecovery(
        callbacks: { 0 }, restartCapture: {},
        restartDaemon: {
          self.restarts += 1
          self.onRestart(self.start)
          return true
        },
        lastDaemonRestart: { self.lastRestart }, now: { 1000 },
        sleep: { try await self.clock.sleep(for: $0) },
        onStalled: {
          self.stalls += 1
          self.stalled.signal()
        })
    }

    func run() -> Task<Void, any Error> {
      let recovery = recovery
      let start = start
      return Task { try await recovery.start { try await start.run(retry: $0) } }
    }
  }

  @Test func aStartThatReturnsInTimeIsLeftAlone() async throws {
    let harness = Harness()
    harness.start.completesAtOnceFromCall = 1
    try await harness.run().value
    #expect(harness.start.calls == 1 && harness.restarts == 0 && harness.stalls == 0)
  }

  @Test func aSlowStartThatStillFinishesInTimeIsNotAStall() async throws {
    let harness = Harness()
    let run = harness.run()
    await harness.clock.waitForSleep(.seconds(5))
    harness.clock.advance(by: .seconds(4))
    harness.start.finish()
    try await run.value
    #expect(harness.restarts == 0 && harness.stalls == 0)
  }

  @Test func aStartTheDaemonRestartFailsIsStartedAgainAsARetry() async throws {
    let harness = Harness()
    harness.start.completesAtOnceFromCall = 2
    let run = harness.run()
    await harness.clock.waitForSleep(.seconds(5))
    harness.clock.advance(by: .seconds(5))
    try await run.value
    #expect(harness.stalls == 1 && harness.restarts == 1)
    #expect(harness.start.retries == [false, true])
  }

  @Test func aStartThatNeverReturnsIsAbandonedOnceTheDaemonIsBack() async throws {
    let harness = Harness()
    harness.start.completesAtOnceFromCall = 2
    harness.onRestart = { _ in }
    let run = harness.run()
    await harness.clock.waitForSleep(.seconds(5))
    harness.clock.advance(by: .seconds(5))
    await harness.clock.waitForSleep(.seconds(1))
    #expect(harness.start.calls == 1, "launchd gets its second before the retry")
    harness.clock.advance(by: .seconds(1))
    try await run.value
    #expect(harness.start.retries == [false, true])
  }

  @Test func aHungStartThatCompletesOnceTheDaemonIsBackIsNotRepeated() async throws {
    let harness = Harness()
    harness.onRestart = { $0.finish() }
    let run = harness.run()
    await harness.clock.waitForSleep(.seconds(5))
    harness.clock.advance(by: .seconds(5))
    try await run.value
    #expect(harness.restarts == 1 && harness.start.calls == 1)
  }

  @Test func withinTheRateLimitAHungStartThatRecoversIsWaitedFor() async throws {
    let harness = Harness()
    harness.lastRestart = 1000 - 30
    let run = harness.run()
    await harness.clock.waitForSleep(.seconds(5))
    harness.clock.advance(by: .seconds(5))
    await harness.stalled.wait()
    #expect(harness.restarts == 0)
    await harness.clock.waitForSleep(.seconds(5), count: 2)
    harness.clock.advance(by: .seconds(4))
    harness.start.finish()
    try await run.value
    #expect(harness.start.calls == 1)
  }

  @Test func withinTheRateLimitAStartThatStaysStuckFailsAfterTenSeconds() async throws {
    let harness = Harness()
    harness.lastRestart = 1000 - 30
    let run = harness.run()
    await harness.clock.waitForSleep(.seconds(5))
    harness.clock.advance(by: .seconds(5))
    await harness.clock.waitForSleep(.seconds(5), count: 2)
    harness.clock.advance(by: .seconds(4))
    #expect(harness.start.calls == 1)
    harness.clock.advance(by: .seconds(1))
    let error = await #expect(throws: ScreenSharingError.self) { try await run.value }
    #expect(error?.localizedDescription == ScreenSharingCaptureStallRecovery.stuck.localizedDescription)
    #expect(harness.restarts == 0 && harness.start.calls == 1)
  }

  @Test func aDaemonRestartedAMinuteAgoMayBeRestartedAgain() async throws {
    let harness = Harness()
    harness.lastRestart = 1000 - 60
    harness.onRestart = { $0.finish() }
    let run = harness.run()
    await harness.clock.waitForSleep(.seconds(5))
    harness.clock.advance(by: .seconds(5))
    try await run.value
    #expect(harness.restarts == 1)
  }

  @Test func aRetryThatHangsOnTheFreshDaemonFailsAfterFiveSeconds() async throws {
    let harness = Harness()
    let run = harness.run()
    await harness.clock.waitForSleep(.seconds(5))
    harness.clock.advance(by: .seconds(5))
    await harness.start.called.wait(for: 2)
    await harness.clock.waitForSleep(.seconds(5), count: 2)
    harness.clock.advance(by: .seconds(5))
    await #expect(throws: ScreenSharingError.self) { try await run.value }
    #expect(harness.start.retries == [false, true])
  }

  @Test func aStopThatHangsIsWaitedForAtMostThreeSeconds() async {
    let clock = TestClock()
    let start = Start()
    let ended = Task {
      await ScreenSharingCaptureStallRecovery.stop(
        { try await start.run(retry: false) }, sleep: { try await clock.sleep(for: $0) })
    }
    await clock.waitForSleep(.seconds(3))
    clock.advance(by: .seconds(3))
    #expect(await ended.value == false)
    let quick = await ScreenSharingCaptureStallRecovery.stop({}, sleep: { try await clock.sleep(for: $0) })
    #expect(quick)
    start.finish()
  }

  @Test func cancellingTheCallerCancelsTheStart() async throws {
    let harness = Harness()
    let run = harness.run()
    await harness.start.called.wait()
    run.cancel()
    harness.start.finish(throwing: CancellationError())
    await #expect(throws: CancellationError.self) { try await run.value }
    #expect(harness.restarts == 0)
  }
}
