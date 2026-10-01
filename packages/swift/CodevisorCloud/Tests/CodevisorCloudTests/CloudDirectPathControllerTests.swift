import CodevisorTestSupport
import Foundation
import Observation
import Testing
import ACPKit
import CodevisorClient
@testable import CodevisorCloud

/// Every dial the controller made, observable so tests can wait on it.
@MainActor
@Observable
final class ProbeLog {
  var probes: [String] = []
}

final class ProbeScript: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [String: ScriptedDirectMachine] = [:]
  private var downCallbacks: [String: @Sendable () -> Void] = [:]
  private var scriptedPath: CloudTunnelPath?
  let log: ProbeLog

  @MainActor init() {
    log = ProbeLog()
  }

  @MainActor var probes: [String] { log.probes }

  func answer(_ deviceId: String, with scripted: ScriptedDirectMachine?) {
    lock.withLock { results[deviceId] = scripted }
  }

  /// The path every pipe reports from now on.
  func report(_ path: CloudTunnelPath?) {
    lock.withLock { scriptedPath = path }
  }

  func takeDown(_ deviceId: String) {
    lock.withLock { downCallbacks[deviceId] }?()
  }
  func downCallback(_ deviceId: String) -> (@Sendable () -> Void)? {
    lock.withLock { downCallbacks[deviceId] }
  }

  var prober: CloudDirectPathController.Prober {
    { [self] machine, onDown in
      await MainActor.run { log.probes.append(machine.deviceId) }
      lock.withLock { downCallbacks[machine.deviceId] = onDown }
      guard let scripted = lock.withLock({ results[machine.deviceId] }) else { return nil }
      let connection = makeDirectConnection(
        to: scripted, directURL: URL(string: "tunnel://\(machine.deviceId)")!, onDown: onDown)
      return CloudDirectPathController.Pipe(connection: connection) { [self] in lock.withLock { scriptedPath } }
    }
  }
}

func testMachine(
  _ deviceId: String,
  publicKey: String,
  online: Bool = true,
  tunnelEndpoint: String? = "endpoint"
) -> CloudMachine {
  CloudMachine(
    deviceId: deviceId,
    name: "Machine \(deviceId)",
    os: "macOS",
    publicKey: publicKey,
    tunnel: tunnelEndpoint.map { CloudTunnelInfo(endpointId: $0) },
    online: online,
    lastSeenAt: "2026-01-01T00:00:00.000Z"
  )
}

@MainActor
func makePathController(
  script: ProbeScript,
  clock: TestClock = TestClock()
) -> CloudDirectPathController {
  CloudDirectPathController(
    credentialStore: InMemoryCloudCredentialStore(),
    reprobeInterval: .seconds(60),
    sleep: clock.sleep,
    prober: script.prober
  )
}

@MainActor
func settle(_ controller: CloudDirectPathController) async {
  for task in controller.probeTasks.values { await task.value }
}

@Suite("CloudDirectPathController")
@MainActor
struct CloudDirectPathControllerTests {
  @Test("A verified tunnel puts the machine on the list; failures and pre-tunnel machines don't")
  func probeOutcomes() async throws {
    let script = ProbeScript()
    let scripted = ScriptedDirectMachine()
    script.answer("m1", with: scripted)
    let controller = makePathController(script: script)

    controller.reconcile(machines: [
      testMachine("m1", publicKey: scripted.machine.publicKey),
      testMachine("m2", publicKey: "other-key"),
      // A server that predates the tunnel has no address to dial.
      testMachine("m3", publicKey: "old-key", tunnelEndpoint: nil),
    ])
    await settle(controller)

    #expect(script.probes.sorted() == ["m1", "m2"])
    #expect(controller.machineIds == ["m1"])
    #expect(controller.transport(for: "m1", publicKey: scripted.machine.publicKey) != nil)
    // A transport is only handed out for the exact verified key the pipe
    // seals toward.
    #expect(controller.transport(for: "m1", publicKey: "imposter") == nil)
    #expect(controller.transport(for: "m2", publicKey: "other-key") == nil)
  }

  @Test("A dropped tunnel re-dials by itself, without a roster refresh")
  func dropRedials() async throws {
    let script = ProbeScript()
    script.answer("m1", with: ScriptedDirectMachine())
    let controller = makePathController(script: script)
    controller.reconcile(machines: [testMachine("m1", publicKey: "key")])
    await settle(controller)
    // A live pipe suppresses re-dialing.
    controller.reconcile(machines: [testMachine("m1", publicKey: "key")])
    await settle(controller)
    #expect(script.probes == ["m1"])

    // The network changed: the pipe drops and a new one comes up unprompted.
    script.answer("m1", with: ScriptedDirectMachine())
    script.takeDown("m1")
    #expect(await waitUntil { script.probes == ["m1", "m1"] })
    await settle(controller)
    #expect(controller.machineIds == ["m1"])
  }

  @Test("A failed dial retries on its own, backing off")
  func failedDialRetries() async throws {
    let script = ProbeScript()
    let clock = TestClock()
    let controller = makePathController(script: script, clock: clock)
    controller.reconcile(machines: [testMachine("m1", publicKey: "key")])
    await settle(controller)
    #expect(controller.machineIds.isEmpty)

    // Unreachable again: the next retry waits twice as long.
    await clock.waitForSleep(.seconds(60))
    clock.advance(by: .seconds(60))
    #expect(await waitUntil { script.probes.count == 2 })
    await settle(controller)
    await clock.waitForSleep(.seconds(120))

    // Reachable now: the next retry brings it up.
    script.answer("m1", with: ScriptedDirectMachine())
    clock.advance(by: .seconds(120))
    #expect(await waitUntil { controller.machineIds == ["m1"] })
    #expect(script.probes == ["m1", "m1", "m1"])
  }

  @Test("A tunnel address arriving after launch dials right away")
  func addressArrivalDials() async throws {
    let script = ProbeScript()
    script.answer("m1", with: ScriptedDirectMachine())
    let controller = makePathController(script: script)

    // The cached roster at launch has no address: nothing to dial.
    controller.reconcile(machines: [testMachine("m1", publicKey: "key", tunnelEndpoint: nil)])
    await settle(controller)
    #expect(script.probes.isEmpty)

    // The fresh roster carries it: dialed at once, no throttle.
    controller.reconcile(machines: [testMachine("m1", publicKey: "key")])
    await settle(controller)
    #expect(controller.machineIds == ["m1"])
  }

  @Test("Opens wait for a tunnel being dialed, and fail clearly when it never comes")
  func awaitTransport() async throws {
    let script = ProbeScript()
    let clock = TestClock()
    let controller = makePathController(script: script, clock: clock)

    // The open starts before the roster has the machine's address.
    let scripted = ScriptedDirectMachine()
    script.answer("m1", with: scripted)
    let waiting = Task { try await controller.awaitTransport(for: "m1", publicKey: "key") }
    await clock.waitForSleep(.seconds(15))
    controller.reconcile(machines: [testMachine("m1", publicKey: "key")])
    #expect(try await waiting.value is CloudDirectTransport)

    // A machine on a server too old for the tunnel: the open times out with
    // an error that says what to do.
    controller.reconcile(machines: [
      testMachine("m1", publicKey: "key"),
      testMachine("old", publicKey: "key", tunnelEndpoint: nil),
    ])
    let stuck = Task { try await controller.awaitTransport(for: "old", publicKey: "key") }
    await clock.waitForSleep(.seconds(15))
    clock.advance(by: .seconds(15))
    await #expect(throws: CloudTunnelUnavailableError(machineDeviceId: "old", hasTunnel: false)) {
      try await stuck.value
    }
  }

  @Test("Removed machines and key changes drop their pipe; dropAll clears everything")
  func teardown() async throws {
    let script = ProbeScript()
    let scripted = ScriptedDirectMachine()
    script.answer("m1", with: scripted)
    let controller = makePathController(script: script)
    let key = scripted.machine.publicKey

    controller.reconcile(machines: [testMachine("m1", publicKey: key)])
    await settle(controller)
    #expect(controller.machineIds == ["m1"])

    // A re-provisioned machine (same id, fresh keys) must not keep a pipe
    // sealing toward the old key.
    script.answer("m1", with: nil)
    controller.reconcile(machines: [testMachine("m1", publicKey: "fresh-key")])
    #expect(controller.transport(for: "m1", publicKey: key) == nil)
    await settle(controller)

    controller.dropAll()
    #expect(controller.machineIds.isEmpty)

    // Gone machines lose their pipe on the next reconcile.
    script.answer("m2", with: ScriptedDirectMachine())
    controller.reconcile(machines: [testMachine("m2", publicKey: key)])
    await settle(controller)
    #expect(controller.machineIds == ["m2"])
    controller.reconcile(machines: [])
    #expect(controller.machineIds.isEmpty)
  }

  @Test("A live pipe publishes its path and round trip, refreshed while it's up; a drop records last seen")
  func pathsAndLastSeen() async throws {
    let script = ProbeScript()
    let clock = TestClock()
    script.answer("m1", with: ScriptedDirectMachine())
    script.report(CloudTunnelPath(isRelayed: false, roundTripMilliseconds: 12))
    let controller = makePathController(script: script, clock: clock)
    controller.reconcile(machines: [testMachine("m1", publicKey: "key")])
    #expect(controller.dialing == ["m1"])
    await settle(controller)
    #expect(controller.dialing.isEmpty)
    #expect(controller.paths["m1"] == CloudTunnelPath(isRelayed: false, roundTripMilliseconds: 12))

    // The network moved it onto a relay: the next refresh shows it.
    let relayed = CloudTunnelPath(
      isRelayed: true, relayURL: "https://relay-sjc-1.codevisor.dev/", roundTripMilliseconds: 48)
    script.report(relayed)
    await clock.waitForSleep(CloudDirectPathController.pathRefreshInterval)
    clock.advance(by: CloudDirectPathController.pathRefreshInterval)
    #expect(await waitUntil { controller.paths["m1"] == relayed })

    // The pipe drops: no path, and "last seen" is now.
    script.answer("m1", with: nil)
    script.takeDown("m1")
    #expect(await waitUntil { controller.paths["m1"] == nil })
    #expect(controller.lastReachable["m1"] != nil)
  }
}
