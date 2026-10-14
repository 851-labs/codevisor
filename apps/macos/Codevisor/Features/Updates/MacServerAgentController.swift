import CodevisorCore
import CodevisorCoreMac
import Foundation
import ServiceManagement
import os

private enum MacServerAgentError: LocalizedError, Sendable {
  case operationPending
  case processDidNotStop
  case requiresApproval
  case registrationDidNotEnable(SMAppService.Status)
  case timedOut(operation: String, after: Duration)

  var errorDescription: String? {
    switch self {
    case .operationPending:
      "A previous macOS background-service request is still pending. Wait for it to finish, then restart Codevisor."
    case .processDidNotStop:
      "The previous background server has not stopped. Codevisor cannot replace it yet."
    case .requiresApproval:
      "Codevisor's background server is turned off in System Settings › General › Login Items & Extensions. Turn it on, then restart Codevisor."
    case let .registrationDidNotEnable(status):
      "macOS did not enable Codevisor's background server (status \(status.rawValue))."
    case let .timedOut(operation, after):
      "macOS did not answer the background-service request '\(operation)' within \(after)."
    }
  }
}

@MainActor
final class MacServerAgentController {
  nonisolated static let plistName = "com.851labs.Codevisor.ServerAgent.plist"
  nonisolated static let jobLabel = "com.851labs.Codevisor.ServerAgent"
  nonisolated static let serviceCallTimeout: Duration = .seconds(15)
  private nonisolated static let callInFlight = OSAllocatedUnfairLock(initialState: false)
  private let legacyJobs = LegacyServerJobRetirer()
  private let lifecycleLog = ServerLifecycleLog.default

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

  private nonisolated static func serviceCall<T: Sendable>(
    _ operation: String,
    _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try Task.checkCancellation()
    guard
      callInFlight.withLock({ busy in
        guard !busy else { return false }
        busy = true
        return true
      })
    else { throw MacServerAgentError.operationPending }
    let outcome = FirstOutcome<T>()
    let started = ContinuousClock.now
    Task.detached {
      let result: Result<T, any Error>
      do {
        result = .success(try await body())
      } catch {
        result = .failure(error)
      }
      callInFlight.withLock { $0 = false }
      if !outcome.resume(with: result) {
        let late = Int((ContinuousClock.now - started) / .milliseconds(1))
        ServerLifecycleLog.default.fault(
          "launchd: '\(operation)' returned \(late) ms after its deadline had already failed the start"
        )
      }
    }
    let timer = Task.detached {
      do { try await Task.sleep(for: serviceCallTimeout) } catch { return }
      _ = outcome.resume(
        with: .failure(MacServerAgentError.timedOut(operation: operation, after: serviceCallTimeout))
      )
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
      try await outcome.value
    } onCancel: {
      _ = outcome.resume(with: .failure(CancellationError()))
    }
  }

  func ensureRegistered() async throws {
    var clock = StepClock()
    let status = try await Self.serviceCall("status") { Self.service.status }
    lifecycleLog.note("launchd: status \(Self.describe(status)) (\(clock.lap()) ms)")
    if status == .requiresApproval { throw MacServerAgentError.requiresApproval }
    if status == .enabled {
      do {
        try await Self.serviceCall("unregister") { try await Self.service.unregister() }
        try await waitForStoppedJob()
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
      try await waitForStoppedJob()
      lifecycleLog.note("launchd: unregistered (\(clock.lap()) ms)")
    } catch {
      lifecycleLog.error("launchd: unregister failed: \(error) (\(clock.lap()) ms)")
      throw error
    }
  }

  private func waitForStoppedJob() async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      if await isJobRunning() == false { return }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw MacServerAgentError.processDidNotStop
  }

  func isJobRunning() async -> Bool? {
    let target = "gui/\(getuid())/\(Self.jobLabel)"
    do {
      let result = try await ProcessCommandRunner().run(
        executableURL: URL(fileURLWithPath: "/bin/launchctl"),
        arguments: ["print", target],
        environment: nil,
        timeout: .seconds(5)
      )
      let running = LaunchctlPrintOutput.isRunning(result)
      if running == nil {
        lifecycleLog.error("launchd: job state is unknown (exit \(result.exitCode)): \(result.standardError)")
      }
      return running
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

nonisolated private final class FirstOutcome<T: Sendable>: @unchecked Sendable {
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
