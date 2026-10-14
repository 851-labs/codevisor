import ScreenSharing
import Foundation

@MainActor
package final class ScreenSharingFirstDrawGate {
  package enum Failure: Error, Equatable { case timedOut, cancelled, tornDown }

  private var continuation: CheckedContinuation<Void, any Error>?
  public private(set) var isSignalled = false
  public private(set) var failure: Failure?

  package init() {}

  package func signal() {
    guard failure == nil else { return }
    isSignalled = true
    resume(.success(()))
  }

  package func wait(timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) async throws {
    if let failure { throw failure }
    if isSignalled { return }
    let deadline = Task { @MainActor [weak self] in
      do { try await sleep(timeout) } catch { return }
      self?.fail(.timedOut)
    }
    defer { deadline.cancel() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, any Error>) in
        if isSignalled { pending.resume(); return }
        if let failure { pending.resume(throwing: failure); return }
        continuation = pending
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.fail(.cancelled) }
    }
  }

  package func teardown() { fail(.tornDown) }

  private func fail(_ reason: Failure) {
    guard failure == nil, !isSignalled else { return }
    failure = reason
    resume(.failure(reason))
  }

  private func resume(_ result: Result<Void, any Error>) {
    guard let pending = continuation else { return }
    continuation = nil
    switch result {
    case .success: pending.resume()
    case .failure(let error): pending.resume(throwing: error)
    }
  }
}

@MainActor
package final class ScreenSharingOwnedWindowSession {
  package typealias Lifecycle = ScreenSharingOwnedWorkloadLifecycle

  public private(set) var lifecycle = Lifecycle()
  public private(set) var hideCount = 0
  public private(set) var startFailure: String?
  public private(set) var stopSucceeded: Bool?
  public private(set) var stopFailure: String?
  public private(set) var cleanupOutcome: Lifecycle.CleanupOutcome?
  private let show: @MainActor () throws -> Void
  private let hide: @MainActor () -> Void
  private let stop: @MainActor () async throws -> Void
  private let now: @MainActor () -> Int64
  public private(set) var stopAttempts = 0

  package init(
    show: @escaping @MainActor () throws -> Void, hide: @escaping @MainActor () -> Void,
    stopCapture: @escaping @MainActor () async throws -> Void,
    now: @escaping @MainActor () -> Int64 = { ScreenSharingMetrics.nowNs }
  ) {
    self.show = show
    self.hide = hide
    self.stop = stopCapture
    self.now = now
  }

  package func start(ready: () async throws -> Void, startCapture: () async throws -> Void) async throws {
    do {
      try lifecycle.apply(.show, atNs: now())
      try show()
      try await ready()
      try Task.checkCancellation()
      try lifecycle.apply(.ready, atNs: now())
      try Task.checkCancellation()
      try await startCapture()
      try lifecycle.apply(.startCapture, atNs: now())
      try Task.checkCancellation()
    } catch {
      startFailure = String(describing: error)
      if lifecycle.state == .capturing { await stopCapture() }
      finish()
      throw error
    }
  }

  package func pauseWorkload(_ pause: () throws -> Void) throws {
    try lifecycle.apply(.pauseWorkload, atNs: now())
    try pause()
  }

  public private(set) var stopRetriesRefused = 0

  @discardableResult
  package func stopCapture() async -> Bool {
    guard lifecycle.state == .capturing || lifecycle.state == .workloadPaused else { return false }
    if stopSucceeded == false {
      stopRetriesRefused += 1
      return false
    }
    stopAttempts += 1
    do {
      try await stop()
      stopSucceeded = true
      try? lifecycle.apply(.stopCapture, atNs: now())
      return true
    } catch {
      stopSucceeded = false
      stopFailure = String(describing: error)
      return false
    }
  }

  @discardableResult
  package func finish() -> Lifecycle.CleanupOutcome {
    if let cleanupOutcome { return cleanupOutcome }
    let outcome = lifecycle.cleanUp(captureStopCompleted: stopSucceeded == true, atNs: now())
    switch outcome {
    case .closedAfterCaptureStop, .abandoned:
      hideCount += 1
      hide()
    case .neverShown, .alreadyFinished: break
    }
    cleanupOutcome = outcome
    return outcome
  }

  package var completedInOrder: Bool { lifecycle.completedInOrder && stopSucceeded == true }

  package var record: [String: Any] {
    [
      "state": lifecycle.state.rawValue, "completedInOrder": completedInOrder,
      "abandonedFrom": lifecycle.abandonedFrom?.rawValue ?? "none",
      "startFailure": startFailure ?? "none", "stopSucceeded": stopSucceeded.map { String($0) } ?? "not attempted",
      "stopFailure": stopFailure ?? "none", "stopAttempts": stopAttempts, "stopRetriesRefused": stopRetriesRefused,
      "cleanup": cleanupOutcome.map { String(describing: $0) } ?? "pending",
      "hideCount": hideCount,
      "timestampsUptimeNs": Dictionary(
        uniqueKeysWithValues: lifecycle.timestampsNs.map { ($0.key.rawValue, $0.value) }),
    ]
  }
}
