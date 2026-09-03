import Foundation
import Testing
import ACPKit
@testable import CodevisorCore
@testable import CodevisorCoreMac

/// The platform-managed (launchd) server path: adoption, failure reporting
/// without any child-process fallback, launchd liveness probing, and the
/// explicit safe-mode escape.
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
      launcher: { request in
        directLaunches += 1
        client.acceptBoot(request.bootId)
        return Process()
      },
      healthPollInterval: .milliseconds(1),
      healthPollAttempts: 2,
      managedStartupPollAttempts: 1,
      staleListenerTerminator: { terminatedPorts.append($0) },
      safeModeStore: makeIsolatedDefaults()
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

  @Test("A managed server that launchd confirms is alive gets the full wait budget")
  func waitsForLiveManagedJob() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    var managed = ServerHealth.running(version: "0.2.0")
    managed.serviceManaged = true
    managed.appOwned = true
    // Many failed probes — far beyond the initial managed budget — before
    // the server answers.
    let client = FakeLocalServerClient(
      healthResults: Array(repeating: .failure(TestError()), count: 30) + [.success(managed)]
    )
    var jobProbes = 0
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: entrypoint,
      launcher: { _ in Process() },
      healthPollInterval: .milliseconds(1),
      healthPollAttempts: 200,
      managedStartupPollAttempts: 4,
      safeModeStore: makeIsolatedDefaults()
    )
    server.configureManagedService(
      LocalCodevisorManagedService(
        start: {},
        stop: {},
        isJobRunning: {
          jobProbes += 1
          return true
        }
      )
    )

    #expect(await server.ensureRunning() == .started)
    #expect(jobProbes >= 1)
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
      launcher: { _ in Process() },
      healthPollInterval: .milliseconds(1),
      healthPollAttempts: 400,
      managedStartupPollAttempts: 400,
      safeModeStore: makeIsolatedDefaults()
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
    #expect(stops == 0)
    // Three "no process" probes, eight attempts apart, not 400 attempts.
    #expect(client.healthCallCount < 40)
  }

  @Test("A registration failure is reported, not worked around")
  func reportsRegistrationFailure() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    let client = FakeLocalServerClient(healthResults: [.failure(TestError())])
    var directLaunches = 0
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: entrypoint,
      launcher: { _ in
        directLaunches += 1
        return Process()
      },
      safeModeStore: makeIsolatedDefaults()
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

  @Test("Safe mode runs the server as an app-owned child once, then forgets the request")
  func safeModeLaunchesChildOnce() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    let client = FakeLocalServerClient(healthResults: [
      .failure(TestError()),
      .success(.ready),
    ])
    var starts = 0
    var directLaunches = 0
    let defaults = makeIsolatedDefaults()
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: entrypoint,
      launcher: { request in
        directLaunches += 1
        client.acceptBoot(request.bootId)
        return Process()
      },
      healthPollInterval: .milliseconds(1),
      safeModeStore: defaults
    )
    server.configureManagedService(
      LocalCodevisorManagedService(start: { starts += 1 }, stop: {})
    )
    server.requestSafeModeOnNextLaunch()
    #expect(defaults.bool(forKey: LocalCodevisorServer.safeModeDefaultsKey))

    #expect(await server.ensureRunning() == .started)

    #expect(starts == 0)
    #expect(directLaunches == 1)
    #expect(server.isInSafeMode)
    // One-shot: the next launch goes back to the managed service.
    #expect(!defaults.bool(forKey: LocalCodevisorServer.safeModeDefaultsKey))
  }
}
