import Foundation
import Testing
@testable import CodevisorCore
@testable import CodevisorCoreMac

@MainActor
@Suite("LocalCodevisorServer startup paths")
struct LocalCodevisorServerStartupPathTests {
  @Test("Adopts a running managed server that matches this build without restarting it")
  func adoptsMatchingManagedServer() async throws {
    let runtime = try StartupRuntime(version: "0.2.0")
    defer { runtime.remove() }
    var managed = ServerHealth.running(version: "0.2.0")
    managed.serviceManaged = true
    let client = FakeLocalServerClient(healthResults: [.success(managed)])
    var starts = 0
    let server = runtime.server(client: client)
    server.configureManagedService(LocalCodevisorManagedService(start: { starts += 1 }, stop: {}))

    #expect(await server.ensureRunning() == .alreadyRunning)
    #expect(starts == 0)
    #expect(client.shutdownRequests == 0)
    #expect(server.startupProgress?.state == "ready")
  }

  @Test("Keeps the server this app launched when ensureRunning runs again")
  func keepsOwnBootOnSecondEnsure() async throws {
    let runtime = try StartupRuntime(version: "0.2.0")
    defer { runtime.remove() }
    let client = FakeLocalServerClient(healthResults: [.failure(TestError()), .success(.running(version: "0.2.0"))])
    var launches = 0
    let server = runtime.server(client: client, allowsDevelopmentLaunch: true) { request in
      launches += 1
      client.acceptBoot(request.bootId)
      return Process()
    }

    #expect(await server.ensureRunning() == .started)
    #expect(await server.ensureRunning() == .alreadyRunning)
    #expect(launches == 1)
    #expect(client.shutdownRequests == 0)
  }

  @Test("Waits for the process it already owns instead of launching another")
  func waitsForOwnedRunningProcess() async throws {
    let runtime = try StartupRuntime(version: "0.2.0")
    defer { runtime.remove() }
    let client = FakeLocalServerClient(healthResults: [
      .failure(TestError()), .failure(TestError()), .failure(TestError()), .success(.running(version: "0.2.0")),
    ])
    var launched: [Process] = []
    let server = runtime.server(client: client, allowsDevelopmentLaunch: true, healthPollAttempts: 1) { request in
      client.acceptBoot(request.bootId)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
      process.arguments = ["-f", "/dev/null"]
      try process.run()
      launched.append(process)
      return process
    }
    defer {
      launched.forEach {
        $0.terminate(); $0.waitUntilExit()
      }
    }

    guard case .unavailable = await server.ensureRunning() else {
      Issue.record("Expected the first wait to time out")
      return
    }
    #expect(await server.ensureRunning() == .started)
    #expect(launched.count == 1)
  }

  @Test("Reports a background service that cannot be prepared")
  func reportsPrepareFailure() async throws {
    let runtime = try StartupRuntime(version: "0.2.0")
    defer { runtime.remove() }
    var starts = 0
    let server = runtime.server(client: FakeLocalServerClient(healthResults: []))
    server.configureManagedService(
      LocalCodevisorManagedService(prepare: { throw TestError() }, start: { starts += 1 }, stop: {}))

    let state = await server.ensureRunning()

    #expect(unavailableMessage(state)?.contains("could not prepare its background service") == true)
    #expect(starts == 0)
  }

  @Test("Reports a stale server that cannot be stopped, without launching over it")
  func reportsUnstoppableStaleServer() async throws {
    let runtime = try StartupRuntime(version: "0.2.0")
    defer { runtime.remove() }
    let client = FakeLocalServerClient(healthResults: [.success(.running(version: "0.1.9"))])
    var launches = 0
    let server = runtime.server(
      client: client, allowsDevelopmentLaunch: true,
      launcher: { _ in
        launches += 1
        return Process()
      }, shutdownProbe: { false })
    server.startupScheduler = AdvancingLocalServerScheduler().scheduler

    let state = await server.ensureRunning()

    #expect(unavailableMessage(state) == "Another Codevisor server is still running and could not be stopped.")
    #expect(client.shutdownRequests == 1)
    #expect(launches == 0)
  }

  @Test("Reports a launch failure and forgets the boot it tried to start")
  func reportsLaunchFailure() async throws {
    let runtime = try StartupRuntime(version: "0.2.0")
    defer { runtime.remove() }
    let server = runtime.server(
      client: FakeLocalServerClient(healthResults: [.failure(TestError())]), allowsDevelopmentLaunch: true
    ) { _ in throw TestError() }

    let state = await server.ensureRunning()

    #expect(unavailableMessage(state)?.hasPrefix("Codevisor server could not be launched") == true)
    #expect(server.activeBootId == nil)
    #expect(server.startupStep == nil)
  }

  @Test("Stops waiting when the server reports a failed startup")
  func reportsFailedStartupProgress() async throws {
    let runtime = try StartupRuntime(version: "0.2.0")
    defer { runtime.remove() }
    let client = FakeLocalServerClient(healthResults: Array(repeating: .failure(TestError()), count: 4))
    let server = runtime.server(client: client)
    server.configureManagedService(
      LocalCodevisorManagedService(
        start: {
          var progress = LocalServerStartupProgress(stage: "openingDatabase", completed: 3, bootId: "failing", pid: 1)
          progress.state = "failed"
          progress.error = "The database is locked."
          try JSONEncoder().encode(progress).write(to: runtime.startupStatusURL, options: .atomic)
        }, stop: {}))

    #expect(await server.ensureRunning() == .unavailable("The database is locked."))
    #expect(client.healthCallCount == 1)
    #expect(!server.startupCanRetry)
  }

  @Test("Reports a launched server that exits before answering")
  func reportsExitedProcess() async throws {
    let runtime = try StartupRuntime(version: "0.2.0")
    defer { runtime.remove() }
    let client = FakeLocalServerClient(healthResults: [.failure(TestError()), .failure(TestError())])
    let server = runtime.server(client: client, allowsDevelopmentLaunch: true) { _ in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
      try process.run()
      process.waitUntilExit()
      return process
    }

    let state = await server.ensureRunning()

    #expect(unavailableMessage(state)?.hasPrefix("Codevisor server exited before becoming ready (status 1)") == true)
    #expect(client.healthCallCount == 2)
  }

  @Test("A cancelled wait stops before probing health")
  func cancelledWaitStops() async throws {
    let runtime = try StartupRuntime(version: "0.2.0")
    defer { runtime.remove() }
    let client = FakeLocalServerClient(healthResults: [])
    let server = runtime.server(client: client)

    let wait = Task { await server.waitUntilHealthy(process: nil, expectedBootId: nil) }
    wait.cancel()

    #expect(await wait.value == .unavailable("Server startup was cancelled."))
    #expect(client.healthCallCount == 0)
  }

  @Test("The app-hosted environment adds the Computer Use socket only when the bridge is running")
  func appHostedEnvironment() {
    let base = ["PATH": "/usr/bin", "CODEVISOR_APP_HOSTED": "0"]
    let bridge = ComputerUseBridge.Configuration(socketPath: "/tmp/cu.sock", token: "secret")

    #expect(
      LocalCodevisorServer.appHostedEnvironment(base, computerUse: nil) == [
        "PATH": "/usr/bin", "CODEVISOR_APP_HOSTED": "1",
      ])
    #expect(
      LocalCodevisorServer.appHostedEnvironment(base, computerUse: bridge) == [
        "PATH": "/usr/bin", "CODEVISOR_APP_HOSTED": "1",
        "CODEVISOR_COMPUTER_USE_SOCKET": "/tmp/cu.sock", "CODEVISOR_COMPUTER_USE_TOKEN": "secret",
      ])
  }
}

@MainActor
private struct StartupRuntime {
  let directory: URL
  let entrypoint: URL

  var startupStatusURL: URL { directory.appendingPathComponent("server-startup.json") }

  init(version: String) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codevisor-startup-paths-\(UUID().uuidString)", isDirectory: true)
    entrypoint = directory.appendingPathComponent("main.js")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try version.write(to: directory.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
  }

  func server(
    client: FakeLocalServerClient,
    allowsDevelopmentLaunch: Bool = false,
    healthPollAttempts: Int = 3,
    launcher: @escaping LocalCodevisorServer.Launcher = { _ in Process() },
    shutdownProbe: (@MainActor () async -> Bool)? = { true }
  ) -> LocalCodevisorServer {
    LocalCodevisorServer(
      client: client,
      allowsDevelopmentLaunch: allowsDevelopmentLaunch,
      entrypoint: entrypoint,
      databasePath: directory.appendingPathComponent("db.sqlite").path,
      logURL: directory.appendingPathComponent("server.log"),
      dataUpgradeStatusURL: directory.appendingPathComponent("data-upgrade.json"),
      startupStatusURL: startupStatusURL,
      serverEnvironmentProvider: { [:] },
      launcher: launcher,
      healthPollInterval: .milliseconds(1),
      healthPollAttempts: healthPollAttempts,
      managedStartupPollAttempts: healthPollAttempts,
      staleListenerTerminator: { _ in },
      shutdownProbe: shutdownProbe
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private func unavailableMessage(_ state: LocalCodevisorServerState) -> String? {
  guard case let .unavailable(message) = state else { return nil }
  return message
}
