import Foundation
import Testing
import ACPKit
@testable import CodevisorCore
@testable import CodevisorCoreMac

extension LocalCodevisorServerTests {
  @Test("Replaces a durable server that is older than the bundled runtime")
  func replacesStaleServer() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    let client = FakeLocalServerClient(healthResults: [
      .success(.running(version: "0.1.9")),  // initial probe: stale server alive
      .failure(TestError()),  // shutdown grace period: it exited
      .success(.running(version: "0.2.0")),  // launched runtime becomes healthy
    ])
    var launches: [LocalCodevisorServerLaunchRequest] = []
    var terminatedPorts: [Int] = []
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: entrypoint,
      launcher: { request in
        launches.append(request)
        client.acceptBoot(request.bootId)
        return Process()
      },
      staleListenerTerminator: { terminatedPorts.append($0) }
    )

    let state = await server.ensureRunning()

    #expect(state == .started)
    #expect(launches.count == 1)
    #expect(client.shutdownRequests == 1)
    #expect(terminatedPorts.isEmpty)
  }

  @Test("Signals a stale server that ignores the shutdown request")
  func signalsStaleServerWithoutShutdownEndpoint() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    let client = FakeLocalServerClient(healthResults: [
      .success(.running(version: "0.1.9")),  // initial probe: stale server alive
      .success(.running(version: "0.1.9")),  // shutdown grace period: still up
      .success(.running(version: "0.1.9")),  // SIGTERM check: still up
      .failure(TestError()),  // post-signal poll: now gone
      .success(.running(version: "0.2.0")),  // launched runtime becomes healthy
    ])
    var launches: [LocalCodevisorServerLaunchRequest] = []
    var terminatedPorts: [Int] = []
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: entrypoint,
      launcher: { request in
        launches.append(request)
        client.acceptBoot(request.bootId)
        return Process()
      },
      staleListenerTerminator: { terminatedPorts.append($0) }
    )

    let state = await server.ensureRunning()

    #expect(state == .started)
    #expect(launches.count == 1)
    #expect(terminatedPorts == [CodevisorServerConfig.localPort])
  }

  @Test("Replaces another app boot even when its runtime version matches")
  func replacesMatchingServerFromAnotherAppBoot() async throws {
    let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
    let client = FakeLocalServerClient(healthResults: [
      .success(.running(version: "0.2.0")),
      .failure(TestError()),
      .success(.running(version: "0.2.0")),
    ])
    var launches: [LocalCodevisorServerLaunchRequest] = []
    var terminatedPorts: [Int] = []
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: entrypoint,
      launcher: { request in
        launches.append(request)
        client.acceptBoot(request.bootId)
        return Process()
      },
      staleListenerTerminator: { terminatedPorts.append($0) }
    )

    let state = await server.ensureRunning()

    #expect(state == .started)
    #expect(launches.count == 1)
    #expect(client.shutdownRequests == 1)
    #expect(terminatedPorts.isEmpty)
  }

  @Test("Keeps a healthy server when the runtime has no VERSION file (dev builds)")
  func keepsServerWithoutBundledVersion() async throws {
    let entrypoint = try makeTemporaryDirectory().appendingPathComponent("main.js")
    let client = FakeLocalServerClient(healthResults: [.success(.running(version: "0.0.1"))])
    var launches: [LocalCodevisorServerLaunchRequest] = []
    let server = LocalCodevisorServer(
      client: client,
      entrypoint: entrypoint,
      launcher: { request in
        launches.append(request)
        return Process()
      },
      staleListenerTerminator: { _ in }
    )

    let state = await server.ensureRunning()

    #expect(state == .alreadyRunning)
    #expect(launches.isEmpty)
  }
}
