import Foundation
import Testing
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

@Suite("CloudHubConnection flow control")
struct CloudHubFlowControlTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var receivedMessages: [Data] = []
        private var closeReasons: [CloudChannelCloseReason?] = []

        var messages: [Data] {
            lock.withLock { receivedMessages }
        }

        var closes: [CloudChannelCloseReason?] {
            lock.withLock { closeReasons }
        }

        func record(_ data: Data) {
            lock.withLock { receivedMessages.append(data) }
        }

        func recordClose(_ reason: CloudChannelCloseReason?) {
            lock.withLock { closeReasons.append(reason) }
        }
    }

    @Test("A flow-controlled channel rejects data beyond its granted ciphertext budget")
    func flowControlEnforcement() async throws {
        let machine = ScriptedRelayMachine()
        let scripted = ScriptedCloudHub(machines: [machine.presence])
        scripted.onRelay = { [weak scripted] envelope in
            guard let scripted, let appKey = scripted.appPublicKey else { return }
            _ = try? machine.receive(envelope.frame, appPublicKey: appKey)
        }
        let store = InMemoryCloudCredentialStore(token: "session-token")
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: store,
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: FakeWebSocketTransport { _ in scripted.socket },
            readyTimeout: .seconds(2)
        )
        let recorder = Recorder()

        let channel = try await hub.openFlowControlledChannel(
            machineDeviceId: machine.deviceId,
            machinePublicKey: machine.publicKey,
            channelType: "byte-stream",
            params: .object(["service": .string("codevisor-loopback"), "version": .number(1)]),
            onMessage: { data, _ in recorder.record(data) },
            onCredit: { _ in },
            onClosed: { recorder.recordClose($0) }
        )
        #expect(await waitUntil { machine.channel(channel.id) != nil })
        // An empty encrypted box costs 22 encoded bytes. Granting only that
        // much cannot authorize the following one-byte payload (23 bytes).
        try await channel.grantCredit(bytes: 22)
        scripted.relayToApp(
            machineId: machine.deviceId,
            frame: try machine.sealData(channelId: channel.id, payload: Data([1]))
        )

        #expect(await waitUntil { recorder.closes == [.protocolError] })
        #expect(recorder.messages.isEmpty)
        await hub.shutdown()
    }
}
