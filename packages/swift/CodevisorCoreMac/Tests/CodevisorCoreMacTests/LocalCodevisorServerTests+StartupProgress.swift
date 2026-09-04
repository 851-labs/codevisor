import Foundation
import Testing
@testable import CodevisorCore
@testable import CodevisorCoreMac

@MainActor
extension LocalCodevisorServerTests {
  @Test("Only fresh forward checkpoints from the current boot extend startup")
  func validatesStartupCheckpoints() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let status = directory.appendingPathComponent("server-startup.json")
    let server = LocalCodevisorServer(
      client: FakeLocalServerClient(healthResults: []),
      databasePath: directory.appendingPathComponent("db.sqlite").path,
      logURL: directory.appendingPathComponent("server.log"), startupStatusURL: status
    )
    server.startupAttemptStartedAt = Date().addingTimeInterval(-1)
    var progress = LocalServerStartupProgress(stage: "loadingRuntime", completed: 2, bootId: "new", pid: 123)
    func write() throws { try JSONEncoder().encode(progress).write(to: status, options: .atomic) }
    try write()
    #expect(server.refreshStartupProgress(expectedBootId: nil))
    #expect(!server.refreshStartupProgress(expectedBootId: "new"))
    progress.bootId = "other"
    try write()
    #expect(!server.refreshStartupProgress(expectedBootId: "new"))
    progress.bootId = "new"
    progress.startedAt = "2020-01-01T00:00:00.000Z"
    try write()
    #expect(!server.refreshStartupProgress(expectedBootId: "new"))
    progress = LocalServerStartupProgress(stage: "openingDatabase", completed: 3, bootId: "new", pid: 123)
    try write()
    #expect(server.refreshStartupProgress(expectedBootId: "new"))
    progress.stage = "acquiringDatabase"
    try write()
    #expect(!server.refreshStartupProgress(expectedBootId: "new"))
    progress.stage = "openingDatabase"
    progress.completed = 7
    try write()
    #expect(!server.refreshStartupProgress(expectedBootId: "new"))
    #expect(server.startupProgress?.completed == 3)
    server.completeStartup()
    #expect(server.startupProgress?.fractionCompleted == 1)
  }

  @Test("An actual checkpoint extends the initial managed startup budget")
  func checkpointsExtendWait() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    let directory = entrypoint.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let status = directory.appendingPathComponent("server-startup.json")
    var health = ServerHealth.running(version: "0.2.0")
    health.serviceManaged = true
    health.bootId = "progress-boot"
    let client = FakeLocalServerClient(
      healthResults: Array(repeating: .failure(TestError()), count: 8) + [.success(health)])
    let server = LocalCodevisorServer(
      client: client, entrypoint: entrypoint, databasePath: directory.appendingPathComponent("db.sqlite").path,
      logURL: directory.appendingPathComponent("server.log"), startupStatusURL: status,
      healthPollInterval: .milliseconds(1), healthPollAttempts: 20, managedStartupPollAttempts: 2
    )
    server.configureManagedService(
      LocalCodevisorManagedService(
        start: {
          let progress = LocalServerStartupProgress(
            stage: "loadingRuntime", completed: 2, bootId: "progress-boot", pid: 123)
          try JSONEncoder().encode(progress).write(to: status, options: .atomic)
        }, stop: {}, isJobRunning: { true }))
    #expect(await server.ensureRunning() == .started)
    #expect(server.startupProgress?.completed == 7)
    #expect(client.healthCallCount == 9)
  }

  @Test("A stalled startup obeys elapsed time even with a live launchd process")
  func stalledStartupDeadline() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = FakeLocalServerClient(healthResults: Array(repeating: .failure(TestError()), count: 100))
    let server = LocalCodevisorServer(
      client: client, databasePath: directory.appendingPathComponent("db.sqlite").path,
      logURL: directory.appendingPathComponent("server.log"), startupStallTimeout: .milliseconds(10),
      healthPollInterval: .milliseconds(2), healthPollAttempts: 100
    )
    let started = ContinuousClock.now
    let state = await server.waitUntilHealthy(process: nil, expectedBootId: nil, jobProbe: { true })
    guard case let .unavailable(message) = state else { Issue.record("Expected timeout"); return }
    #expect(message.contains("stopped progressing"))
    #expect(ContinuousClock.now - started < .seconds(1))
  }

  @Test("Shutdown verifies ownership even when HTTP no longer answers")
  func shutdownWaitsForOwnership() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = FakeLocalServerClient(healthResults: [.failure(TestError())])
    var checks = 0
    var signals = 0
    let server = LocalCodevisorServer(
      client: client, databasePath: directory.appendingPathComponent("db.sqlite").path,
      logURL: directory.appendingPathComponent("server.log"),
      staleListenerTerminator: { _ in signals += 1 },
      shutdownProbe: {
        checks += 1; return checks >= 3
      }
    )
    #expect(await server.shutdown())
    #expect(checks == 3)
    #expect(signals == 1)
    #expect(client.healthCallCount == 0)
  }

  @Test("Update drain has a final deadline after requesting interruption once")
  func updateDrainFinalDeadline() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = FakeLocalServerClient(healthResults: [])
    client.drainResult = ServerRestartDrainState(state: "draining", remaining: 1)
    let server = LocalCodevisorServer(
      client: client,
      databasePath: directory.appendingPathComponent("db.sqlite").path,
      logURL: directory.appendingPathComponent("server.log"))
    let started = ContinuousClock.now
    #expect(
      await !server.drainForAppUpdate(
        onStatus: { _ in }, drainTimeout: .milliseconds(5),
        interruptionTimeout: .milliseconds(10), pollInterval: .milliseconds(1)))
    #expect(client.drainInterruptions == 1)
    #expect(ContinuousClock.now - started < .seconds(1))
    client.drainResult = ServerRestartDrainState(state: "drained", remaining: 0)
    #expect(await server.drainForAppUpdate(onStatus: { _ in }))
  }

  @Test("A deadline returns even when its operation ignores cancellation")
  func requestDeadlineIgnoresLateResult() async throws {
    var continuation: CheckedContinuation<Int, Never>?
    let task = Task {
      try await StartupDeadline.run(for: .milliseconds(10)) {
        await withCheckedContinuation { continuation = $0 }
      }
    }
    do {
      _ = try await task.value
      Issue.record("Expected request timeout")
    } catch { #expect(error is StartupDeadlineError) }
    continuation?.resume(returning: 42)
    #expect(try await StartupDeadline.run(for: .seconds(1)) { 7 } == 7)
  }
}
