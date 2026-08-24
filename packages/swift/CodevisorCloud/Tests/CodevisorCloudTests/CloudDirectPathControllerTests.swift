import Foundation
import Testing
import ACPKit
import CodevisorClient
@testable import CodevisorCloud

/// A transport that must never be asked to open a channel — reconcile hands
/// it to the prober, which the fakes here don't exercise.
private struct UnusedTransport: CloudChannelTransport {
    var machineDeviceId: String

    func openChannel(
        channelType: String,
        params: JSONValue?,
        compressed: Bool,
        onMessage: @escaping @Sendable (Data) -> Void,
        onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
        throw CloudHubConnectionError.disconnected
    }

    func openFlowControlledChannel(
        channelType: String,
        params: JSONValue?,
        compressed: Bool,
        onMessage: @escaping @Sendable (Data, Int) -> Void,
        onCredit: @escaping @Sendable (Int) -> Void,
        onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
        throw CloudHubConnectionError.disconnected
    }
}

private final class ProbeScript: @unchecked Sendable {
    private let lock = NSLock()
    private var probed: [String] = []
    private var results: [String: ScriptedDirectMachine] = [:]
    private var downCallbacks: [String: @Sendable () -> Void] = [:]

    var probes: [String] {
        lock.withLock { probed }
    }

    func answer(_ deviceId: String, with scripted: ScriptedDirectMachine) {
        lock.withLock { results[deviceId] = scripted }
    }

    func takeDown(_ deviceId: String) {
        lock.withLock { downCallbacks[deviceId] }?()
    }

    var prober: CloudDirectPathController.Prober {
        { [self] machine, _, onDown in
            lock.withLock {
                probed.append(machine.deviceId)
                downCallbacks[machine.deviceId] = onDown
            }
            guard let scripted = lock.withLock({ results[machine.deviceId] }) else { return nil }
            return makeDirectConnection(to: scripted, onDown: onDown)
        }
    }
}

private func testMachine(
    _ deviceId: String,
    publicKey: String,
    online: Bool = true
) -> CloudMachine {
    CloudMachine(
        deviceId: deviceId,
        name: "Machine \(deviceId)",
        os: "macOS",
        publicKey: publicKey,
        online: online,
        lastSeenAt: "2026-01-01T00:00:00.000Z"
    )
}

@MainActor
private func makePathController(
    script: ProbeScript,
    reprobeInterval: Duration = .seconds(60)
) -> CloudDirectPathController {
    CloudDirectPathController(
        credentialStore: InMemoryCloudCredentialStore(),
        reprobeInterval: reprobeInterval,
        prober: script.prober
    )
}

@MainActor
private func settle(_ controller: CloudDirectPathController) async {
    _ = await waitUntil { await MainActor.run { controller.probeTasks.isEmpty } }
}

@Suite("CloudDirectPathController")
@MainActor
struct CloudDirectPathControllerTests {
    @Test("A verified probe puts the machine on the direct list; failures don't")
    func probeOutcomes() async throws {
        let script = ProbeScript()
        let scripted = ScriptedDirectMachine()
        script.answer("m1", with: scripted)
        let controller = makePathController(script: script)
        let machines = [
            testMachine("m1", publicKey: scripted.machine.publicKey),
            testMachine("m2", publicKey: "other-key"),
        ]

        controller.reconcile(machines: machines) { UnusedTransport(machineDeviceId: $0.deviceId) }
        await settle(controller)

        #expect(script.probes.sorted() == ["m1", "m2"])
        #expect(controller.machineIds == ["m1"])
        #expect(controller.transport(for: "m1", publicKey: scripted.machine.publicKey) != nil)
        // A transport is only handed out for the exact verified key the pipe
        // seals toward.
        #expect(controller.transport(for: "m1", publicKey: "imposter") == nil)
        #expect(controller.transport(for: "m2", publicKey: "other-key") == nil)
    }

    @Test("Probes are throttled; a dead pipe re-probes immediately")
    func throttling() async throws {
        let script = ProbeScript()
        let scripted = ScriptedDirectMachine()
        script.answer("m1", with: scripted)
        let controller = makePathController(script: script)
        let machines = [testMachine("m1", publicKey: scripted.machine.publicKey)]
        let relay = { (machine: CloudMachine) -> any CloudChannelTransport in
            UnusedTransport(machineDeviceId: machine.deviceId)
        }

        controller.reconcile(machines: machines, relayTransport: relay)
        await settle(controller)
        // A live pipe (or a too-recent attempt) suppresses re-probing.
        controller.reconcile(machines: machines, relayTransport: relay)
        await settle(controller)
        #expect(script.probes == ["m1"])

        // The pipe dying is fresh information: the throttle resets.
        script.takeDown("m1")
        #expect(await waitUntil { await MainActor.run { controller.machineIds.isEmpty } })
        controller.reconcile(machines: machines, relayTransport: relay)
        await settle(controller)
        #expect(script.probes == ["m1", "m1"])
    }

    @Test("LAN→relay failover: a dead direct pipe routes the next open over the relay")
    func lanToRelayFailover() async throws {
        // One machine, two pipes: a scripted LAN listener and a scripted
        // relay machine behind a scripted hub, sharing the device id.
        let direct = ScriptedDirectMachine()
        let deviceId = direct.machine.deviceId
        let relayMachine = ScriptedRelayMachine(deviceId: deviceId)
        let scriptedHub = ScriptedCloudHub(machines: [relayMachine.presence])
        scriptedHub.onRelay = { envelope in
            guard let appKey = scriptedHub.appPublicKey else { return }
            _ = try? relayMachine.receive(
                envelope.frame, payload: envelope.payload, appPublicKey: appKey)
        }
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: InMemoryCloudCredentialStore(token: "session-token"),
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: FakeWebSocketTransport { _ in scriptedHub.socket },
            readyTimeout: .seconds(2)
        )
        let relayEndpoint = CloudRelayEndpoint(
            hub: hub,
            machineDeviceId: deviceId,
            machinePublicKey: relayMachine.publicKey
        )

        let script = ProbeScript()
        script.answer(deviceId, with: direct)
        let controller = makePathController(script: script)
        controller.reconcile(
            machines: [testMachine(deviceId, publicKey: direct.machine.publicKey)]
        ) { UnusedTransport(machineDeviceId: $0.deviceId) }
        await settle(controller)
        #expect(controller.machineIds.contains(deviceId))

        // The one transport every consumer would hold: best pipe per open.
        let key = direct.machine.publicKey
        let transport = SwitchingChannelTransport(machineDeviceId: deviceId) {
            await controller.transport(for: deviceId, publicKey: key) ?? relayEndpoint
        }

        // While the direct pipe is up, channels land on the LAN listener.
        let overDirect = try await transport.openChannel(
            channelType: "http", params: nil, compressed: false,
            onMessage: { _ in }, onClosed: { _ in })
        #expect(await waitUntil { direct.machine.channel(overDirect.id) != nil })
        #expect(relayMachine.channel(overDirect.id) == nil)

        // WiFi gone: the pipe dies, and the very next open rides the relay.
        direct.socket.disconnect()
        #expect(await waitUntil { await MainActor.run { controller.machineIds.isEmpty } })
        let overRelay = try await transport.openChannel(
            channelType: "http", params: nil, compressed: false,
            onMessage: { _ in }, onClosed: { _ in })
        #expect(await waitUntil { relayMachine.channel(overRelay.id) != nil })
        #expect(direct.machine.channel(overRelay.id) == nil)
        await hub.shutdown()
    }

    @Test("Removed machines and key changes drop their pipe; dropAll clears everything")
    func teardown() async throws {
        let script = ProbeScript()
        let scripted = ScriptedDirectMachine()
        script.answer("m1", with: scripted)
        let controller = makePathController(script: script)
        let relay = { (machine: CloudMachine) -> any CloudChannelTransport in
            UnusedTransport(machineDeviceId: machine.deviceId)
        }

        controller.reconcile(
            machines: [testMachine("m1", publicKey: scripted.machine.publicKey)],
            relayTransport: relay
        )
        await settle(controller)
        #expect(controller.machineIds == ["m1"])

        // A re-provisioned machine (same id, fresh keys) must not keep a pipe
        // sealing toward the old key.
        controller.reconcile(
            machines: [testMachine("m1", publicKey: "fresh-key")],
            relayTransport: relay
        )
        #expect(controller.transport(for: "m1", publicKey: scripted.machine.publicKey) == nil)
        await settle(controller)

        controller.dropAll()
        #expect(controller.machineIds.isEmpty)

        // Gone machines lose their pipe on the next reconcile.
        script.answer("m2", with: scripted)
        controller.reconcile(
            machines: [testMachine("m2", publicKey: scripted.machine.publicKey)],
            relayTransport: relay
        )
        await settle(controller)
        #expect(controller.machineIds == ["m2"])
        controller.reconcile(machines: [], relayTransport: relay)
        #expect(controller.machineIds.isEmpty)
    }
}
