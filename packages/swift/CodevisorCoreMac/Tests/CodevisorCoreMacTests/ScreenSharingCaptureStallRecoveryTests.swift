import Darwin
import Foundation
import Testing
@testable import CodevisorCoreMac

/// The stalled-capture recovery (851-2385) against a scripted capture and daemon: no real
/// ScreenCaptureKit, `replayd` or clock. Each sleep advances a virtual clock; the capture
/// calls back once per poll while it delivers.
@MainActor
struct ScreenSharingCaptureStallRecoveryTests {
  @MainActor final class Host {
    enum Step: Equatable { case restartCapture, restartDaemon }
    /// Whether the running capture calls back; `restart` and `daemon` decide what each restart gives.
    var delivering: Bool
    var restartDelivers = false
    var restartThrows = false
    /// A fresh daemon makes the next capture restart deliver.
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
    // It noticed within one poll, not after the whole grace period.
    #expect(host.time - 1000 == 0.25)
  }

  @Test func silenceShorterThanTheGraceIsNotAStall() async throws {
    let host = Host(delivering: false)
    let recovery = host.recovery
    // The first callback lands on the last poll before the deadline.
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
    // Stalled after the 3 s grace, delivering again one poll after the restart.
    #expect(host.time - 1000 == 3.25)
  }

  @Test func aStuckDaemonIsRestartedAndTheCaptureWithIt() async throws {
    let host = Host(delivering: false)
    #expect(try await host.recovery.run(baseline: 0) == .recovered(restartedDaemon: true))
    #expect(host.steps == [.restartCapture, .restartDaemon, .restartCapture])
    #expect(host.stalls == 1)
    // 3 s grace, 3 s after the first restart, 1 s for launchd, one poll: well inside ~10 s.
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
    // The session ends (its capture task is cancelled) the moment the stall is found.
    recovery.onStalled = { withUnsafeCurrentTask { $0?.cancel() } }
    let run = Task { try await recovery.run(baseline: 0) }
    await #expect(throws: CancellationError.self) { try await run.value }
    #expect(!host.steps.contains(.restartDaemon))
  }

  /// The lookup behind the kill, on this test process instead of `replayd`: found by name among
  /// this user's processes, with its descriptors counted. Nothing is killed.
  @Test func theDaemonLookupFindsThisUsersProcessByName() throws {
    let name = try #require(ScreenSharingCaptureDaemon.processName(getpid()))
    #expect(ScreenSharingCaptureDaemon.processes(named: name).contains(getpid()))
    #expect((ScreenSharingCaptureDaemon.descriptorCount(getpid()) ?? 0) > 0)
    #expect(ScreenSharingCaptureDaemon.processes(named: "no-such-process-\(UUID().uuidString.prefix(8))").isEmpty)
  }

  @Test func activityCountsCallbacksAndDeliveredFrames() {
    #expect(ScreenSharingCaptureStallRecovery.activity([:]) == 0)
    #expect(ScreenSharingCaptureStallRecovery.activity(["capturedFrames": 2]) == 2)
    #expect(ScreenSharingCaptureStallRecovery.activity(["capturedFrames": 2, "unrelated": 7]) == 2)
  }
}
