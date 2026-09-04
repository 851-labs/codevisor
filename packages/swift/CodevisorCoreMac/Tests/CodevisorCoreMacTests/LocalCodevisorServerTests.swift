import Foundation
import Testing
import ACPKit
@testable import CodevisorCore
@testable import CodevisorCoreMac

@MainActor
@Suite("LocalCodevisorServer")
struct LocalCodevisorServerTests {
  @Test("Uses an already healthy local server without launching")
  func alreadyRunning() async {
    let client = FakeLocalServerClient(healthResults: [.success(.ready)])
    var launches: [LocalCodevisorServerLaunchRequest] = []
    let server = LocalCodevisorServer(
      client: client,
      allowsDevelopmentLaunch: true,
      entrypoint: URL(fileURLWithPath: "/tmp/main.js"),
      launcher: { request in
        launches.append(request)
        return Process()
      }
    )

    let state = await server.ensureRunning()

    #expect(state == .alreadyRunning)
    #expect(launches.isEmpty)
  }

  @Test("Launches the server entrypoint and waits for health")
  func launchesAndWaitsForHealth() async {
    let entrypoint = URL(fileURLWithPath: "/tmp/codevisor-server/main.js")
    let client = FakeLocalServerClient(healthResults: [.failure(TestError()), .success(.ready)])
    var launches: [LocalCodevisorServerLaunchRequest] = []
    let server = LocalCodevisorServer(
      client: client,
      allowsDevelopmentLaunch: true,
      entrypoint: entrypoint,
      nodeExecutable: URL(fileURLWithPath: "/usr/bin/node"),
      databasePath: "/tmp/codevisor.sqlite",
      logURL: URL(fileURLWithPath: "/tmp/codevisor-server.log"),
      serverEnvironmentProvider: {
        ["PATH": "/opt/homebrew/bin:/usr/bin", "CODEVISOR_TEST": "1"]
      },
      launcher: { request in
        launches.append(request)
        client.acceptBoot(request.bootId)
        return Process()
      }
    )

    let state = await server.ensureRunning()

    #expect(state == .started)
    #expect(launches.first?.entrypoint == entrypoint)
    #expect(launches.first?.databasePath == "/tmp/codevisor.sqlite")
    #expect(launches.first?.host == "0.0.0.0")
    #expect(launches.first?.name == CodevisorMachine.local.name)
    #expect(launches.first?.port == CodevisorServerConfig.localPort)
    #expect(launches.first?.environment["PATH"] == "/opt/homebrew/bin:/usr/bin")
    #expect(launches.first?.environment["CODEVISOR_TEST"] == "1")
  }

  @Test("Publishes blocking data-upgrade progress while waiting for health")
  func publishesDataUpgradeProgress() async throws {
    let directory = try makeTemporaryDirectory()
    let statusURL = directory.appendingPathComponent("data-upgrade.json")
    let client = FakeLocalServerClient(healthResults: [
      .failure(TestError()),  // pre-launch probe
      .failure(TestError()),  // first wait iteration while migrating
      .success(.ready),
    ])
    let running = LocalDataUpgradeProgress(
      state: "running",
      id: "canonical-chat-v1",
      name: "Updating chat history",
      completed: 25,
      total: 100
    )
    let completed = LocalDataUpgradeProgress(
      state: "completed",
      id: running.id,
      name: running.name,
      completed: 100,
      total: 100
    )
    // The upgrade finishes exactly when the server first reports healthy
    // (the third health call: pre-launch probe, one failing wait
    // iteration, then success). Keying the status-file write to the
    // health sequence instead of a timer keeps the test deterministic on
    // loaded CI machines, where a detached sleeping task can lose the
    // race against the wait loop's final progress refresh.
    var launchedBootId: String?
    client.onHealth = { call in
      guard call == 3 else { return }
      var scoped = completed
      scoped.bootId = launchedBootId
      try? JSONEncoder().encode(scoped).write(to: statusURL, options: .atomic)
    }
    var launchedProcess: Process?
    let server = LocalCodevisorServer(
      client: client,
      allowsDevelopmentLaunch: true,
      entrypoint: directory.appendingPathComponent("main.js"),
      dataUpgradeStatusURL: statusURL,
      serverEnvironmentProvider: { [:] },
      launcher: { request in
        #expect(request.dataUpgradeStatusURL == statusURL)
        launchedBootId = request.bootId
        client.acceptBoot(request.bootId)
        var scoped = running
        scoped.bootId = request.bootId
        try JSONEncoder().encode(scoped).write(to: statusURL, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        // Far longer than the test can run: a stalled CI runner once
        // took over a second to reach the healthy poll iteration, at
        // which point a short-lived fake process had already exited
        // and tripped the "server exited before ready" branch.
        process.arguments = ["600"]
        try process.run()
        launchedProcess = process
        return process
      }
    )
    defer { launchedProcess?.terminate() }

    let result = Task { await server.ensureRunning() }
    for _ in 0..<200 where server.dataUpgradeProgress == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(server.dataUpgradeProgress?.state == running.state)
    #expect(server.dataUpgradeProgress?.bootId == launchedBootId)
    #expect(await result.value == .started)
    #expect(server.dataUpgradeProgress == nil)
  }

  @Test("Ignores migration progress written by another server boot")
  func ignoresStaleDataUpgradeProgress() async throws {
    let directory = try makeTemporaryDirectory()
    let statusURL = directory.appendingPathComponent("data-upgrade.json")
    let stale = LocalDataUpgradeProgress(
      state: "running",
      id: "attachment-object-store-v1",
      name: "Moving attachments to disk",
      completed: 10,
      total: 100,
      bootId: "old-boot"
    )
    try JSONEncoder().encode(stale).write(to: statusURL, options: .atomic)
    let client = FakeLocalServerClient(healthResults: [
      .failure(TestError()),
      .failure(TestError()),
      .success(.ready),
    ])
    var launchedProcess: Process?
    let server = LocalCodevisorServer(
      client: client,
      allowsDevelopmentLaunch: true,
      entrypoint: directory.appendingPathComponent("main.js"),
      dataUpgradeStatusURL: statusURL,
      serverEnvironmentProvider: { [:] },
      launcher: { request in
        client.acceptBoot(request.bootId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["600"]
        try process.run()
        launchedProcess = process
        return process
      }
    )
    defer { launchedProcess?.terminate() }

    let result = Task { await server.ensureRunning() }
    try await Task.sleep(for: .milliseconds(100))
    #expect(server.dataUpgradeProgress == nil)
    #expect(await result.value == .started)
  }

  @Test("Rejects health from a different server boot")
  func rejectsDifferentBootHealth() async {
    var wrong = ServerHealth.ready
    wrong.bootId = "different-boot"
    let client = FakeLocalServerClient(healthResults: [
      .failure(TestError()),
      .success(wrong),
    ])
    let server = LocalCodevisorServer(
      client: client,
      allowsDevelopmentLaunch: true,
      entrypoint: URL(fileURLWithPath: "/tmp/main.js"),
      launcher: { _ in Process() }
    )

    let state = await server.ensureRunning()

    guard case let .unavailable(message) = state else {
      Issue.record("expected a boot ownership failure")
      return
    }
    #expect(message.contains("different Codevisor server"))
  }

  @Test("Concurrent ensureRunning calls share one launch")
  func concurrentEnsureRunningLaunchesOnce() async {
    let client = FakeLocalServerClient(healthResults: [.failure(TestError()), .success(.ready)])
    var launches = 0
    let server = LocalCodevisorServer(
      client: client,
      allowsDevelopmentLaunch: true,
      entrypoint: URL(fileURLWithPath: "/tmp/main.js"),
      serverEnvironmentProvider: {
        // Suspend mid-launch so the second caller arrives while the
        // first is still in flight — the historical double-launch
        // window (onboarding and the root view racing on first run).
        try? await Task.sleep(for: .milliseconds(50))
        return [:]
      },
      launcher: { request in
        client.acceptBoot(request.bootId)
        launches += 1
        return Process()
      }
    )

    async let first = server.ensureRunning()
    async let second = server.ensureRunning()
    let states = await [first, second]

    #expect(states == [.started, .started])
    #expect(launches == 1)
  }

  @Test("Reports unavailable when no server entrypoint can be found")
  func missingEntrypoint() async {
    let client = FakeLocalServerClient(healthResults: [.failure(TestError())])
    let server = LocalCodevisorServer(client: client, allowsDevelopmentLaunch: true, entrypoint: nil)

    let state = await server.ensureRunning()

    guard case let .unavailable(message) = state else {
      Issue.record("expected unavailable")
      return
    }
    #expect(message.contains("entrypoint"))
  }

  func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codevisor-server-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// A runtime directory shaped like a release bundle's: main.js beside a
  /// VERSION file. Returns the entrypoint URL.
  func makeRuntimeEntrypoint(version: String) throws -> URL {
    let directory = try makeTemporaryDirectory()
    try version.write(
      to: directory.appendingPathComponent("VERSION"),
      atomically: true,
      encoding: .utf8
    )
    return directory.appendingPathComponent("main.js")
  }
}

struct TestError: Error {}

extension ServerHealth {
  static let ready = ServerHealth(ok: true, version: "0.1.0", database: "ready")

  static func running(version: String) -> ServerHealth {
    ServerHealth(ok: true, version: version, database: "ready")
  }
}

final class FakeLocalServerClient: CodevisorServerClienting, @unchecked Sendable {
  private let lock = NSLock()
  private var healthResults: [Result<ServerHealth, Error>]
  private(set) var shutdownRequests = 0
  private var healthCalls = 0
  var healthCallCount: Int { lock.withLock { healthCalls } }
  private var acceptedBootId: String?
  /// Runs on every health() call with the 1-based call number, before the
  /// result is returned. Lets tests key side effects (like data-upgrade
  /// status file writes) to the health sequence instead of wall-clock
  /// timers, which lose scheduling races on loaded CI machines.
  var onHealth: ((Int) -> Void)?

  init(healthResults: [Result<ServerHealth, Error>]) {
    self.healthResults = healthResults
  }

  func acceptBoot(_ bootId: String) {
    lock.withLock { acceptedBootId = bootId }
  }

  func health() async throws -> ServerHealth {
    let (result, call, bootId): (Result<ServerHealth, Error>, Int, String?) = lock.withLock {
      healthCalls += 1
      return (
        healthResults.isEmpty ? .success(.ready) : healthResults.removeFirst(),
        healthCalls,
        acceptedBootId
      )
    }
    onHealth?(call)
    switch result {
    case var .success(health):
      if health.bootId == nil {
        health.bootId = bootId
      }
      return health
    case let .failure(error):
      throw error
    }
  }

  var drainResult = ServerRestartDrainState(state: "drained", remaining: 0)
  var drainInterruptions = 0

  func beginRestartDrain(interrupt: Bool) async throws -> ServerRestartDrainState {
    lock.withLock {
      if interrupt { drainInterruptions += 1 }
      return drainResult
    }
  }

  func restartDrainState() async throws -> ServerRestartDrainState { lock.withLock { drainResult } }

  func requestShutdown() async throws {
    lock.withLock { shutdownRequests += 1 }
  }

  func listHarnesses() async throws -> [ServerHarness] { [] }
  func info() async throws -> ServerInfo { fatalError("unused") }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    fatalError("unused")
  }
  func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
  func listProjects() async throws -> [ServerProject] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func listSessions() async throws -> [ServerSession] { [] }
  func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
  func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
  }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { continuation in continuation.finish() }
  }
}
