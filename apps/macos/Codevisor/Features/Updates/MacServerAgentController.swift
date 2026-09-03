import CodevisorCore
import CodevisorCoreMac
import Foundation
import ServiceManagement
import os

private enum MacServerAgentError: LocalizedError, Sendable {
  case requiresApproval
  case registrationDidNotEnable(SMAppService.Status)
  case timedOut(operation: String, after: Duration)

  var errorDescription: String? {
    switch self {
    case .requiresApproval:
      "Codevisor's background server is turned off in System Settings › General › Login Items & Extensions. Turn it on, then restart Codevisor."
    case let .registrationDidNotEnable(status):
      "macOS did not enable Codevisor's background server (status \(status.rawValue))."
    case let .timedOut(operation, after):
      "macOS did not answer the background-service request '\(operation)' within \(after)."
    }
  }
}

/// Registers the bundled server with launchd. The service is per-user,
/// relocatable with the signed app bundle, and survives app/UI restarts.
///
/// Every call into ServiceManagement runs under a deadline. The calls are
/// synchronous XPC round trips to `smd`; one that never returns (seen right
/// after a bundle swap) used to pin app startup for minutes with nothing in
/// any log. Now it fails within `serviceCallTimeout`, and every outcome —
/// status, register, unregister, timing — lands in the server timeline.
@MainActor
final class MacServerAgentController {
  nonisolated static let plistName = "com.851labs.Codevisor.ServerAgent.plist"
  nonisolated static let jobLabel = "com.851labs.Codevisor.ServerAgent"
  nonisolated static let serviceCallTimeout: Duration = .seconds(15)
  private let legacyJobs = LegacyServerJobRetirer()
  private let lifecycleLog = ServerLifecycleLog.default

  // Constructed on demand (it is cheap) so each detached closure below can
  // build its own instance instead of sending one across isolation domains.
  private nonisolated static var service: SMAppService {
    SMAppService.agent(plistName: plistName)
  }

  var managedService: LocalCodevisorManagedService {
    LocalCodevisorManagedService(
      prepare: { [weak self] in try await self?.retireLegacyJobs() },
      start: { [weak self] in try await self?.ensureRegistered() },
      stop: { [weak self] in try await self?.unregister() },
      isJobRunning: { [weak self] in await self?.isJobRunning() }
    )
  }

  private func retireLegacyJobs() async throws {
    try await legacyJobs.retire()
  }

  /// Runs one ServiceManagement call off the main actor under a deadline.
  ///
  /// Not a task group: a group waits for every child before it returns,
  /// and a synchronous XPC call that never comes back cannot be cancelled —
  /// the deadline would fire and then wait anyway. The call runs on a
  /// detached task instead; whichever of it and the timer finishes first
  /// resumes the caller. A call that returns after the deadline is logged
  /// so the timeline shows how long macOS actually took.
  private nonisolated static func serviceCall<T: Sendable>(
    _ operation: String,
    _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let outcome = FirstOutcome<T>()
    let started = ContinuousClock.now
    Task.detached {
      let result: Result<T, any Error>
      do {
        result = .success(try await body())
      } catch {
        result = .failure(error)
      }
      if !outcome.resume(with: result) {
        let late = Int((ContinuousClock.now - started) / .milliseconds(1))
        ServerLifecycleLog.default.fault(
          "launchd: '\(operation)' returned \(late) ms after its deadline had already failed the start"
        )
      }
    }
    Task.detached {
      try? await Task.sleep(for: serviceCallTimeout)
      _ = outcome.resume(
        with: .failure(MacServerAgentError.timedOut(operation: operation, after: serviceCallTimeout))
      )
    }
    return try await outcome.value
  }

  func ensureRegistered() async throws {
    var clock = StepClock()
    // SMAppService.status/register/unregister are synchronous XPC round
    // trips to launchd/smd, so keep them off the main actor.
    let status = try await Self.serviceCall("status") { Self.service.status }
    lifecycleLog.note("launchd: status \(Self.describe(status)) (\(clock.lap()) ms)")
    // This closure is reached only when no matching service is healthy.
    // Re-register an enabled-but-dead job so launchd resolves BundleProgram
    // against the app bundle that is running now, never an updater backup.
    if status == .enabled {
      do {
        try await Self.serviceCall("unregister") { try await Self.service.unregister() }
        lifecycleLog.note("launchd: unregistered the stale job (\(clock.lap()) ms)")
      } catch {
        lifecycleLog.error("launchd: unregister failed: \(error) (\(clock.lap()) ms)")
        throw error
      }
    }
    do {
      try await Self.serviceCall("register") { try Self.service.register() }
      lifecycleLog.note("launchd: register returned (\(clock.lap()) ms)")
    } catch {
      lifecycleLog.error("launchd: register failed: \(error) (\(clock.lap()) ms)")
      throw error
    }
    // `register()` can return successfully while macOS leaves the item
    // awaiting approval. Anything short of enabled is a failure the user
    // must resolve; the app never silently runs a child server instead.
    let after = try await Self.serviceCall("status") { Self.service.status }
    lifecycleLog.note("launchd: status after register \(Self.describe(after)) (\(clock.lap()) ms)")
    switch after {
    case .enabled:
      return
    case .requiresApproval:
      throw MacServerAgentError.requiresApproval
    case .notRegistered, .notFound:
      throw MacServerAgentError.registrationDidNotEnable(after)
    @unknown default:
      throw MacServerAgentError.registrationDidNotEnable(after)
    }
  }

  func unregister() async throws {
    var clock = StepClock()
    let status = try await Self.serviceCall("status") { Self.service.status }
    guard status == .enabled || status == .requiresApproval else {
      lifecycleLog.note("launchd: nothing to unregister (status \(Self.describe(status)))")
      return
    }
    do {
      try await Self.serviceCall("unregister") { try await Self.service.unregister() }
      lifecycleLog.note("launchd: unregistered (\(clock.lap()) ms)")
    } catch {
      lifecycleLog.error("launchd: unregister failed: \(error) (\(clock.lap()) ms)")
      throw error
    }
  }

  /// Whether launchd has a live process for the job right now, via
  /// `launchctl print` (the only public view of a job's pid). Nil when the
  /// answer is unknown — launchctl hung or its output was unreadable.
  func isJobRunning() async -> Bool? {
    let target = "gui/\(getuid())/\(Self.jobLabel)"
    do {
      let result = try await ProcessCommandRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/launchctl"),
        arguments: ["print", target],
        environment: nil,
        timeout: .seconds(5)
      )
      guard result.exitCode == 0 else {
        // Not loaded at all (exit 113 / "Could not find service").
        return false
      }
      return LaunchctlPrintOutput.pid(in: result.standardOutput) != nil
    } catch {
      lifecycleLog.error("launchd: could not read the job state: \(error)")
      return nil
    }
  }

  private nonisolated static func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown(\(status.rawValue))"
    }
  }

  /// Drains and stops the local server ahead of a bundle swap. `onStatus`
  /// receives progress such as "Waiting for 2 chats to finish…".
  func prepareForAppUpdate(
    localServer: (any LocalServerControlling)?,
    onStatus: @escaping @MainActor (String) -> Void = { _ in }
  ) async -> Bool {
    do {
      try await retireLegacyJobs()
    } catch {
      lifecycleLog.error("Legacy server cleanup failed before update: \(error)")
      return false
    }
    if let localServer {
      return await localServer.prepareForAppUpdate(onStatus: onStatus)
    } else {
      do {
        try await unregister()
        return true
      } catch {
        lifecycleLog.error("ServerAgent unregister failed before update: \(error)")
        return false
      }
    }
  }
}

/// Resumes exactly one waiter with whichever result arrives first; later
/// results report that they lost the race.
private final class FirstOutcome<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, any Error>?
  private var pending: Result<T, any Error>?
  private var resumed = false

  var value: T {
    get async throws {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if let pending {
          resumed = true
          lock.unlock()
          continuation.resume(with: pending)
          return
        }
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  /// True when this result is the one delivered to the waiter.
  func resume(with result: Result<T, any Error>) -> Bool {
    lock.lock()
    guard !resumed, pending == nil else {
      lock.unlock()
      return false
    }
    if let continuation {
      resumed = true
      self.continuation = nil
      lock.unlock()
      continuation.resume(with: result)
      return true
    }
    pending = result
    lock.unlock()
    return true
  }
}
