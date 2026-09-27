import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCloud

@Suite("Cloud hub presence recovery")
struct CloudHubPresenceRecoveryTests {
  @Test("Only a machine-wide offline error marks a machine offline; the REST roster heals it")
  func offlineErrorsAndAuthoritativeRoster() async throws {
    let machine = ScriptedRelayMachine()
    let scripted = ScriptedCloudHub(machines: [machine.presence])
    let (hub, _) = makeHub(scripted)

    try await hub.waitUntilReady()
    // A channel-scoped failure says nothing about the machine's presence.
    scripted.errorToApp(
      code: "machine-offline",
      message: "machine is not connected",
      machineId: machine.deviceId,
      channelId: "channel-1"
    )
    await scripted.socket.drain()
    #expect(await hub.machines.first?.online == true)

    // The grace-expiry broadcast carries machine-wide authority.
    scripted.errorToApp(
      code: "machine-offline",
      message: "resume grace expired",
      machineId: machine.deviceId
    )
    await scripted.socket.drain()
    #expect(await hub.machines.first?.online == false)

    await hub.reconcileAuthoritativeMachines([machine.presence])
    #expect(await hub.machines.first?.online == true)
    await hub.shutdown()
  }
}
