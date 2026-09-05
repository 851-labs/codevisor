import Foundation
import Testing
import ACPKit
@testable import CodevisorCore
@testable import CodevisorCoreMac

/// The platform-managed (launchd) server path: adoption, failure reporting
/// without any child-process fallback, launchd liveness probing, and the
/// production ownership policy.
@MainActor
extension LocalCodevisorServerTests {
  @Test("Starts and adopts the platform-managed server")
  func startsManagedServer() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    var managed = ServerHealth.running(version: "0.2.0")
    managed.serviceManaged = true
    managed.appOwned = true
    let client = FakeLocalServerClient(healthResults: [
      .failure(TestError()),
      .success(managed),
    ])
    var prepares = 0
    var starts = 0
    var directLaunches = 0
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: entrypoint,
      serverEnvironmentProvider: { [:] },
      launcher: { _ in
        directLaunches += 1
        return Process()
      }
    )
    server.configureManagedService(
      LocalCodevisorManagedService(
        prepare: { prepares += 1 },
        start: { starts += 1 },
        stop: {}
      )
    )

    #expect(await server.ensureRunning() == .started)
    #expect(prepares == 1)
    #expect(starts == 1)
    #expect(directLaunches == 0)
  }

  @Test("A managed server that never becomes healthy is reported, never replaced by a child")
  func reportsDeadManagedServer() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    let client = FakeLocalServerClient(healthResults: [
      .failure(TestError()),
      // A process answering with the wrong bundled identity is just as
      // unusable as an agent script that exited before binding.
      .success(.ready),
    ])
    var starts = 0
    var stops = 0
    var directLaunches = 0
    var terminatedPorts: [Int] = []
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: entrypoint,
      serverEnvironmentProvider: { [:] },
      launcher: { request in
        directLaunches += 1
        client.acceptBoot(request.bootId)
        return Process()
      },
      healthPollInterval: .milliseconds(1),
      healthPollAttempts: 2,
      managedStartupPollAttempts: 1,
      staleListenerTerminator: { terminatedPorts.append($0) }
    )
    server.configureManagedService(
      LocalCodevisorManagedService(
        start: { starts += 1 },
        stop: { stops += 1 }
      )
    )

    let state = await server.ensureRunning()

    guard case let .unavailable(message) = state else {
      Issue.record("Expected unavailable, got \(state)")
      return
    }
    #expect(message.contains("does not match this Codevisor build"))
    #expect(starts == 1)
    // The job is left for the log and the next attempt; nothing is torn
    // down and no app-owned server is launched in its place.
    #expect(stops == 0)
    #expect(directLaunches == 0)
    #expect(terminatedPorts.isEmpty)
  }

  @Test("A live process without startup progress exhausts its budget and retries once")
  func liveJobDoesNotExtendBudget() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    let client = FakeLocalServerClient(healthResults: Array(repeating: .failure(TestError()), count: 100))
    var starts = 0
    var stops = 0
    let server = LocalCodevisorServer(
      client: client, entrypoint: entrypoint,
      databasePath: entrypoint.deletingLastPathComponent().appendingPathComponent("db.sqlite").path,
      logURL: entrypoint.deletingLastPathComponent().appendingPathComponent("server.log"),
      healthPollInterval: .milliseconds(1), healthPollAttempts: 100,
      managedStartupPollAttempts: 4, shutdownProbe: { true }
    )
    server.configureManagedService(
      LocalCodevisorManagedService(
        start: { starts += 1 }, stop: { stops += 1 }, isJobRunning: { true }
      ))
    guard case .unavailable = await server.ensureRunning() else {
      Issue.record("Expected a stalled start to fail")
      return
    }
    #expect(starts == 2)
    #expect(stops == 1)
    #expect(client.healthCallCount == 9)
  }

  @Test("A managed job with no live process fails fast instead of waiting out the budget")
  func failsFastForDeadManagedJob() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    let client = FakeLocalServerClient(
      healthResults: Array(repeating: .failure(TestError()), count: 400)
    )
    var stops = 0
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: entrypoint,
      serverEnvironmentProvider: { [:] },
      launcher: { _ in Process() },
      healthPollInterval: .milliseconds(1),
      healthPollAttempts: 400,
      managedStartupPollAttempts: 400,
      shutdownProbe: { true }
    )
    server.configureManagedService(
      LocalCodevisorManagedService(
        start: {},
        stop: { stops += 1 },
        isJobRunning: { false }
      )
    )

    let state = await server.ensureRunning()

    guard case let .unavailable(message) = state else {
      Issue.record("Expected unavailable, got \(state)")
      return
    }
    #expect(message.contains("exited before becoming ready"))
    #expect(stops == 1)
    // Three "no process" probes, eight attempts apart, not 400 attempts.
    #expect(client.healthCallCount < 60)
  }

  @Test("A stalled managed start recovers after one verified shutdown")
  func retryRecoversManagedServer() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    let directory = entrypoint.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    var healthy = ServerHealth.running(version: "0.2.0")
    healthy.serviceManaged = true
    let client = FakeLocalServerClient(healthResults: [
      .failure(TestError()), .failure(TestError()), .success(healthy),
    ])
    var starts = 0
    var stops = 0
    var verified = false
    let server = LocalCodevisorServer(
      client: client, entrypoint: entrypoint, databasePath: directory.appendingPathComponent("db.sqlite").path,
      logURL: directory.appendingPathComponent("server.log"),
      healthPollInterval: .milliseconds(1), healthPollAttempts: 2, managedStartupPollAttempts: 1,
      shutdownProbe: {
        verified = true; return true
      }
    )
    server.configureManagedService(
      LocalCodevisorManagedService(
        start: {
          starts += 1
          if starts == 2 { #expect(verified) }
        }, stop: { stops += 1 }, isJobRunning: { true }))
    #expect(await server.ensureRunning() == .started)
    #expect(starts == 2)
    #expect(stops == 1)
    let diagnostics = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("startup-failure-") }
    #expect(diagnostics.count == 1)
  }

  @Test("A registration failure is reported, not worked around")
  func reportsRegistrationFailure() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    let client = FakeLocalServerClient(healthResults: [.failure(TestError())])
    var directLaunches = 0
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: entrypoint,
      serverEnvironmentProvider: { [:] },
      launcher: { _ in
        directLaunches += 1
        return Process()
      }
    )
    server.configureManagedService(
      LocalCodevisorManagedService(
        start: { throw TestError() },
        stop: {}
      )
    )

    let state = await server.ensureRunning()

    guard case let .unavailable(message) = state else {
      Issue.record("Expected unavailable, got \(state)")
      return
    }
    #expect(message.contains("background server could not be started"))
    #expect(directLaunches == 0)
  }

  @Test("Production cannot fall back to an app-owned server")
  func productionRequiresManagedService() async throws {
    let client = FakeLocalServerClient(healthResults: [.failure(TestError())])
    var launched = false
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: try makeRuntimeEntrypoint(version: "0.2.0"),
      serverEnvironmentProvider: { [:] },
      launcher: { _ in
        launched = true; return Process()
      }
    )
    guard case .unavailable = await server.ensureRunning() else {
      Issue.record("Expected missing service to fail")
      return
    }
    #expect(!launched)
  }
}
