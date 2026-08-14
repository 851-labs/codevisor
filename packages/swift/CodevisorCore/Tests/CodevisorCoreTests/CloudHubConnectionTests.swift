import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@Suite("CloudHubConnection")
struct CloudHubConnectionTests {
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

    private final class CountingCredentialStore: CloudCredentialStore, @unchecked Sendable {
        private let base: InMemoryCloudCredentialStore
        private let lock = NSLock()
        private var tokenReadCount = 0
        private var deviceIdReadCount = 0
        private var secretKeyReadCount = 0

        init(base: InMemoryCloudCredentialStore) {
            self.base = base
        }

        var readCounts: (token: Int, deviceId: Int, secretKey: Int) {
            lock.withLock { (tokenReadCount, deviceIdReadCount, secretKeyReadCount) }
        }

        func token() throws -> String? {
            lock.withLock { tokenReadCount += 1 }
            return try base.token()
        }

        func saveToken(_ token: String) throws { try base.saveToken(token) }
        func removeToken() throws { try base.removeToken() }
        func serverURL() throws -> URL? { try base.serverURL() }
        func saveServerURL(_ url: URL?) throws { try base.saveServerURL(url) }

        func appDeviceId() throws -> String? {
            lock.withLock { deviceIdReadCount += 1 }
            return try base.appDeviceId()
        }

        func saveAppDeviceId(_ id: String) throws { try base.saveAppDeviceId(id) }

        func appSecretKey() throws -> Data? {
            lock.withLock { secretKeyReadCount += 1 }
            return try base.appSecretKey()
        }

        func saveAppSecretKey(_ key: Data) throws { try base.saveAppSecretKey(key) }
    }

    private final class SocketQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var sockets: [any ServerWebSocketConnecting]

        init(_ sockets: [any ServerWebSocketConnecting]) {
            self.sockets = sockets
        }

        func next() -> any ServerWebSocketConnecting {
            lock.withLock {
                if sockets.count > 1 { return sockets.removeFirst() }
                return sockets[0]
            }
        }
    }

    private func makeHub(
        _ scripted: ScriptedCloudHub,
        heartbeatInterval: Duration = .seconds(30),
        heartbeatTimeout: Duration = .seconds(10)
    ) -> (hub: CloudHubConnection, store: InMemoryCloudCredentialStore) {
        let store = InMemoryCloudCredentialStore(token: "session-token")
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: store,
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: FakeWebSocketTransport { _ in scripted.socket },
            readyTimeout: .seconds(2),
            heartbeatInterval: heartbeatInterval,
            heartbeatTimeout: heartbeatTimeout
        )
        return (hub, store)
    }

    @Test("Connects with hello and adopts the welcome's machine list")
    func helloWelcome() async throws {
        let machine = ScriptedRelayMachine()
        let scripted = ScriptedCloudHub(machines: [machine.presence])
        let (hub, _) = makeHub(scripted)

        try await hub.waitUntilReady()
        #expect(scripted.sawHello)
        #expect(scripted.appPublicKey?.isEmpty == false)
        let machines = await hub.machines
        #expect(machines.map(\.deviceId) == [machine.deviceId])
        await hub.shutdown()
    }

    @Test("A hub snapshots credentials instead of rereading them per channel")
    func credentialsAreReadOnce() async throws {
        let machine = ScriptedRelayMachine()
        let scripted = ScriptedCloudHub(machines: [machine.presence])
        let memory = InMemoryCloudCredentialStore(token: "session-token")
        try memory.saveAppDeviceId("app-device")
        try memory.saveAppSecretKey(Data(repeating: 7, count: 32))
        let store = CountingCredentialStore(base: memory)
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: store,
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: FakeWebSocketTransport { _ in scripted.socket },
            readyTimeout: .seconds(2)
        )

        try await hub.waitUntilReady()
        for _ in 0..<4 {
            _ = try await hub.openChannel(
                machineDeviceId: machine.deviceId,
                machinePublicKey: machine.publicKey,
                channelType: "test",
                params: nil,
                onMessage: { _ in },
                onClosed: { _ in }
            )
        }

        let counts = store.readCounts
        #expect(counts.token == 1)
        #expect(counts.deviceId == 1)
        #expect(counts.secretKey == 1)
        await hub.shutdown()
    }

    @Test("Hub reconnects reuse the credential snapshot")
    func reconnectUsesCredentialSnapshot() async throws {
        let first = ScriptedCloudHub()
        let second = ScriptedCloudHub()
        let sockets = SocketQueue([first.socket, second.socket])
        let transport = FakeWebSocketTransport { _ in sockets.next() }
        let memory = InMemoryCloudCredentialStore(token: "session-token")
        try memory.saveAppDeviceId("app-device")
        try memory.saveAppSecretKey(Data(repeating: 7, count: 32))
        let store = CountingCredentialStore(base: memory)
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: store,
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: transport,
            readyTimeout: .seconds(3)
        )

        try await hub.waitUntilReady()
        first.socket.disconnect()
        #expect(await waitUntil(timeout: .seconds(3)) { transport.requests.count == 2 })
        try await hub.waitUntilReady()

        let counts = store.readCounts
        #expect(counts.token == 1)
        #expect(counts.deviceId == 1)
        #expect(counts.secretKey == 1)
        await hub.shutdown()
    }

    @Test("Channel opens park while a known machine is offline")
    func offlineMachineParksChannelOpen() async throws {
        let machine = ScriptedRelayMachine()
        var offlinePresence = machine.presence
        offlinePresence.online = false
        let scripted = ScriptedCloudHub(machines: [offlinePresence])
        let (hub, _) = makeHub(scripted)

        try await hub.waitUntilReady()
        let openTask = Task {
            try await hub.openChannel(
                machineDeviceId: machine.deviceId,
                machinePublicKey: machine.publicKey,
                channelType: "test",
                params: nil,
                onMessage: { _ in },
                onClosed: { _ in }
            )
        }

        try await Task.sleep(for: .milliseconds(25))
        #expect(scripted.relayEnvelopes.isEmpty)

        var onlinePresence = offlinePresence
        onlinePresence.online = true
        scripted.presenceToApp(onlinePresence)
        _ = try await openTask.value
        #expect(await waitUntil { scripted.relayEnvelopes.count == 1 })
        await hub.shutdown()
    }

    @Test("A machine-offline hub error updates presence and parks later channel opens")
    func machineOfflineErrorParksChannelOpen() async throws {
        let machine = ScriptedRelayMachine()
        let scripted = ScriptedCloudHub(machines: [machine.presence])
        let (hub, _) = makeHub(scripted)
        let recorder = Recorder()

        let first = try await hub.openChannel(
            machineDeviceId: machine.deviceId,
            machinePublicKey: machine.publicKey,
            channelType: "test",
            params: nil,
            onMessage: { _ in },
            onClosed: { recorder.recordClose($0) }
        )
        #expect(await waitUntil { scripted.relayEnvelopes.count == 1 })

        scripted.errorToApp(
            code: "machine-offline",
            message: "machine is not connected",
            machineId: machine.deviceId,
            channelId: first.id
        )
        #expect(await waitUntil { recorder.closes == [nil] })
        #expect(await hub.machines.first?.online == false)

        let secondOpen = Task {
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
        #expect(scripted.relayEnvelopes.count == 1)

        scripted.presenceToApp(machine.presence)
        _ = try await secondOpen.value
        #expect(await waitUntil { scripted.relayEnvelopes.count == 2 })
        await hub.shutdown()
    }

    @Test("A missing heartbeat pong replaces a half-open socket")
    func heartbeatTimeoutReconnects() async throws {
        let first = ScriptedCloudHub()
        first.respondsToPing = false
        let second = ScriptedCloudHub()
        let sockets = SocketQueue([first.socket, second.socket])
        let transport = FakeWebSocketTransport { _ in sockets.next() }
        let store = InMemoryCloudCredentialStore(token: "session-token")
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: store,
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: transport,
            readyTimeout: .seconds(2),
            heartbeatInterval: .milliseconds(20),
            heartbeatTimeout: .milliseconds(20)
        )

        try await hub.waitUntilReady()
        #expect(await waitUntil(timeout: .seconds(3)) { transport.requests.count >= 2 })
        try await hub.waitUntilReady()
        await hub.shutdown()
    }

    @Test("An outbound send failure replaces the hub socket")
    func sendFailureReconnects() async throws {
        let machine = ScriptedRelayMachine()
        let first = ScriptedCloudHub(machines: [machine.presence])
        let second = ScriptedCloudHub(machines: [machine.presence])
        let sockets = SocketQueue([first.socket, second.socket])
        let transport = FakeWebSocketTransport { _ in sockets.next() }
        let store = InMemoryCloudCredentialStore(token: "session-token")
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: store,
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: transport,
            readyTimeout: .seconds(2)
        )

        try await hub.waitUntilReady()
        first.socket.failsSends = true
        _ = try await hub.openChannel(
            machineDeviceId: machine.deviceId,
            machinePublicKey: machine.publicKey,
            channelType: "test",
            params: nil,
            onMessage: { _ in },
            onClosed: { _ in }
        )
        #expect(await waitUntil(timeout: .seconds(3)) { transport.requests.count >= 2 })
        try await hub.waitUntilReady()
        await hub.shutdown()
    }

    @Test("Lifecycle reconnect immediately replaces the current socket")
    func lifecycleReconnect() async throws {
        let first = ScriptedCloudHub()
        let second = ScriptedCloudHub()
        let sockets = SocketQueue([first.socket, second.socket])
        let transport = FakeWebSocketTransport { _ in sockets.next() }
        let store = InMemoryCloudCredentialStore(token: "session-token")
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: store,
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: transport,
            readyTimeout: .seconds(2)
        )

        try await hub.waitUntilReady()
        await hub.reconnect()
        #expect(await waitUntil(timeout: .seconds(3)) { transport.requests.count >= 2 })
        try await hub.waitUntilReady()
        await hub.shutdown()
    }

    @Test("Opens channels, routes sealed frames, and books seqs per direction")
    func channelMux() async throws {
        let machine = ScriptedRelayMachine()
        let scripted = ScriptedCloudHub(machines: [machine.presence])
        scripted.onRelay = { [weak scripted] envelope in
            guard let scripted, let appKey = scripted.appPublicKey else { return }
            _ = try? machine.receive(envelope.frame, appPublicKey: appKey)
        }
        let (hub, _) = makeHub(scripted)
        let recorder = Recorder()

        let channel = try await hub.openChannel(
            machineDeviceId: machine.deviceId,
            machinePublicKey: machine.publicKey,
            channelType: "test",
            params: .object(["hello": .string("world")]),
            onMessage: { recorder.record($0) },
            onClosed: { recorder.recordClose($0) }
        )

        // The machine saw the open (seq 0) and decrypted its payload.
        #expect(await waitUntil { machine.channel(channel.id)?.openPayload != nil })
        let openPayload = try #require(machine.channel(channel.id)?.openPayload)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: openPayload)
        #expect(decoded["channelType"] == .string("test"))
        #expect(decoded["params"]?["hello"] == .string("world"))

        // App → machine data frames carry seq 1, 2, ... after the open.
        try await channel.sendJSON(["kind": "first"])
        try await channel.sendJSON(["kind": "second"])
        #expect(await waitUntil { machine.channel(channel.id)?.messages.count == 2 })
        let sentSeqs = scripted.relayEnvelopes.filter {
            if case .data = $0.frame { return true }
            return false
        }.map(\.frame.seq)
        #expect(sentSeqs == [1, 2])

        // Machine → app data frames (seq 0, 1) decrypt and arrive in order.
        scripted.relayToApp(
            machineId: machine.deviceId,
            frame: try machine.sealData(channelId: channel.id, payload: Data("reply-1".utf8))
        )
        scripted.relayToApp(
            machineId: machine.deviceId,
            frame: try machine.sealData(channelId: channel.id, payload: Data("reply-2".utf8))
        )
        #expect(await waitUntil { recorder.messages.count == 2 })
        #expect(recorder.messages.map { String(decoding: $0, as: UTF8.self) } == ["reply-1", "reply-2"])

        // Consuming data replenishes the peer's window with credit frames.
        #expect(
            await waitUntil {
                scripted.relayEnvelopes.contains {
                    if case .credit = $0.frame { return true }
                    return false
                }
            })

        // A machine-initiated close reaches onClosed with its reason.
        scripted.relayToApp(
            machineId: machine.deviceId,
            frame: machine.closeFrame(channelId: channel.id, reason: .done)
        )
        #expect(await waitUntil { recorder.closes == [.done] })
        await hub.shutdown()
    }

    @Test("A seq gap on the responder direction kills the channel as protocol-error")
    func seqEnforcement() async throws {
        let machine = ScriptedRelayMachine()
        let scripted = ScriptedCloudHub(machines: [machine.presence])
        scripted.onRelay = { [weak scripted] envelope in
            guard let scripted, let appKey = scripted.appPublicKey else { return }
            _ = try? machine.receive(envelope.frame, appPublicKey: appKey)
        }
        let (hub, _) = makeHub(scripted)
        let recorder = Recorder()

        let channel = try await hub.openChannel(
            machineDeviceId: machine.deviceId,
            machinePublicKey: machine.publicKey,
            channelType: "test",
            params: nil,
            onMessage: { recorder.record($0) },
            onClosed: { recorder.recordClose($0) }
        )
        #expect(await waitUntil { machine.channel(channel.id) != nil })

        // Frame with seq 4 when 0 is expected → protocol error: the channel
        // closes locally and a close frame goes back to the peer.
        let sealed = try machine.channel(channel.id)!.cipher.seal(
            Data("late".utf8), channelId: channel.id, direction: .responderToOpener, seq: 4
        )
        scripted.relayToApp(
            machineId: machine.deviceId,
            frame: .data(channelId: channel.id, seq: 4, sealed: CloudSealedPayload(box: sealed))
        )
        #expect(await waitUntil { recorder.closes == [.protocolError] })
        #expect(recorder.messages.isEmpty)
        #expect(
            await waitUntil {
                scripted.relayEnvelopes.contains {
                    if case let .close(_, _, reason) = $0.frame { return reason == .protocolError }
                    return false
                }
            })

        // The dead channel rejects further sends.
        await #expect(throws: CloudHubConnectionError.channelClosed) {
            try await channel.sendJSON(["kind": "after-close"])
        }
        await hub.shutdown()
    }

    @Test("Undecryptable frames kill the channel as crypto-error")
    func cryptoErrorClosesChannel() async throws {
        let machine = ScriptedRelayMachine()
        let scripted = ScriptedCloudHub(machines: [machine.presence])
        let (hub, _) = makeHub(scripted)
        let recorder = Recorder()

        let channel = try await hub.openChannel(
            machineDeviceId: machine.deviceId,
            machinePublicKey: machine.publicKey,
            channelType: "test",
            params: nil,
            onMessage: { recorder.record($0) },
            onClosed: { recorder.recordClose($0) }
        )
        scripted.relayToApp(
            machineId: machine.deviceId,
            frame: .data(
                channelId: channel.id,
                seq: 0,
                sealed: CloudSealedPayload(
                    box: CloudChannelCrypto.base64URLEncode(Data(repeating: 9, count: 32))
                )
            )
        )
        #expect(await waitUntil { recorder.closes == [.cryptoError] })
        await hub.shutdown()
    }

    @Test("Connection loss fails open channels with nil and channels die with the socket")
    func connectionLossFailsChannels() async throws {
        let machine = ScriptedRelayMachine()
        let scripted = ScriptedCloudHub(machines: [machine.presence])
        let (hub, _) = makeHub(scripted)
        let recorder = Recorder()

        _ = try await hub.openChannel(
            machineDeviceId: machine.deviceId,
            machinePublicKey: machine.publicKey,
            channelType: "test",
            params: nil,
            onMessage: { recorder.record($0) },
            onClosed: { recorder.recordClose($0) }
        )
        scripted.socket.disconnect()
        #expect(await waitUntil { recorder.closes == [nil] })
        await hub.shutdown()
    }

    @Test("Fatal hub close codes stop reconnecting")
    func fatalCloseCode() async throws {
        let scripted = ScriptedCloudHub()
        scripted.socket.closeCodeOnDisconnect = URLSessionWebSocketTask.CloseCode(rawValue: 4200)!
        let (hub, _) = makeHub(scripted)
        try await hub.waitUntilReady()
        scripted.socket.disconnect()

        // Once the fatal close is observed, openChannel fails fast instead of
        // retrying forever.
        #expect(
            await waitUntil {
                do {
                    try await hub.waitUntilReady()
                    return false
                } catch let error as CloudHubConnectionError {
                    return error == .rejected(closeCode: 4200)
                } catch {
                    return false
                }
            })
        await hub.shutdown()
    }

    @Test("Missing token is fatal (hub outlived its sign-in)")
    func missingTokenFatal() async throws {
        let scripted = ScriptedCloudHub()
        let store = InMemoryCloudCredentialStore()
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: store,
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: FakeWebSocketTransport { _ in scripted.socket },
            readyTimeout: .seconds(2)
        )
        await #expect(throws: CloudHubConnectionError.notSignedIn) {
            try await hub.waitUntilReady()
        }
        await hub.shutdown()
    }

    @Test("The connect URL carries the session token on the /connect path")
    func connectURL() async throws {
        let scripted = ScriptedCloudHub()
        let transport = FakeWebSocketTransport { _ in scripted.socket }
        let store = InMemoryCloudCredentialStore(token: "session-token")
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: store,
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: transport,
            readyTimeout: .seconds(2)
        )
        try await hub.waitUntilReady()
        #expect(transport.requests.first?.absoluteString == "wss://cloud.example.com/connect?token=session-token")
        await hub.shutdown()
    }

    @Test("Tokens with query-hostile characters are strictly percent-encoded")
    func connectURLEncodesToken() async throws {
        // Session tokens are base64 with "+", "/" and "=". URLComponents
        // leaves those literal, but the hub decodes the query per the WHATWG
        // standard where "+" is a space — the token must arrive fully encoded
        // or the hub authenticates the wrong session (see the app joining a
        // stale cookie's account instead of its own).
        let scripted = ScriptedCloudHub()
        let transport = FakeWebSocketTransport { _ in scripted.socket }
        let store = InMemoryCloudCredentialStore(token: "a+b/c=.d+e=")
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: store,
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: transport,
            readyTimeout: .seconds(2)
        )
        try await hub.waitUntilReady()
        #expect(
            transport.requests.first?.absoluteString
                == "wss://cloud.example.com/connect?token=a%2Bb%2Fc%3D.d%2Be%3D"
        )
        await hub.shutdown()
    }
}
