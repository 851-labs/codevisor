import Foundation
import Testing
@testable import CodevisorCloud

@Suite("Cloud hub presence recovery")
struct CloudHubPresenceRecoveryTests {
  @Test("The authoritative roster heals machine-wide stale offline state")
  func authoritativeRosterResumesParkedChannelOpen() async throws {
    let machine = ScriptedRelayMachine()
    let scripted = ScriptedCloudHub(machines: [machine.presence])
    let (hub, _) = makeHub(scripted)

    try await hub.waitUntilReady()
    scripted.errorToApp(
      code: "machine-offline",
      message: "resume grace expired",
      machineId: machine.deviceId
    )
    #expect(await waitUntil { await hub.machines.first?.online == false })

    let open = Task {
      try await hub.openChannel(
        machineDeviceId: machine.deviceId,
        machinePublicKey: machine.publicKey,
        channelType: "test",
        params: nil,
        onMessage: { _ in },
        onClosed: { _ in }
      )
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(scripted.relayEnvelopes.isEmpty)

    await hub.reconcileAuthoritativeMachines([machine.presence])
    _ = try await open.value
    #expect(await waitUntil { scripted.relayEnvelopes.count == 1 })
    await hub.shutdown()
  }
}
