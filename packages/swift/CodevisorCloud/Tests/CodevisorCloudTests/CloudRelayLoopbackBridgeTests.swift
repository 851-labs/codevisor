import CodevisorClient
import Foundation
import Network
import Testing
@testable import CodevisorCloud

private final class RawTCPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "raw-cloud-tunnel-client")
    private var buffer = Data()

    init(port: UInt16) {
        connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                let result: Result<Void, any Error>
                switch state {
                case .ready: result = .success(())
                case let .failed(error): result = .failure(error)
                case .cancelled: result = .failure(URLError(.cancelled))
                default: return
                }
                guard once.claim() else { return }
                continuation.resume(with: result)
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data, isComplete: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: isComplete && data.isEmpty ? nil : data,
                contentContext: isComplete ? .finalMessage : .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    func readExactly(_ count: Int) async throws -> Data {
        let timeout = Task { [connection] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer { timeout.cancel() }
        while buffer.count < count {
            guard let chunk = try await receiveChunk() else { throw URLError(.badServerResponse) }
            buffer.append(chunk)
        }
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }

    func waitForEOF() async throws {
        let timeout = Task { [connection] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer { timeout.cancel() }
        while let chunk = try await receiveChunk() {
            buffer.append(chunk)
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if complete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                let first = !claimed
                claimed = true
                return first
            }
        }
    }
}

@Suite("CloudRelayLoopbackBridge")
struct CloudRelayLoopbackBridgeTests {
    private final class ScriptedByteMachine: @unchecked Sendable {
        private struct OpenPayload: Decodable {
            struct Params: Decodable {
                var service: String
                var version: Int
            }

            var channelType: String
            var params: Params
        }

        let machine = ScriptedRelayMachine()
        let hub: ScriptedCloudHub
        private let lock = NSLock()
        private let automaticallyGrantInitialCredit: Bool
        private var channelIds: [String] = []
        private var received = Data()
        private var creditGrants: [Int] = []
        private var receivedFIN = false
        private var closeReasons: [CloudChannelCloseReason] = []

        init(automaticallyGrantInitialCredit: Bool = true) {
            self.automaticallyGrantInitialCredit = automaticallyGrantInitialCredit
            hub = ScriptedCloudHub(machines: [machine.presence])
            hub.onRelay = { [weak self] envelope in
                self?.handle(envelope)
            }
        }

        var channelId: String? { lock.withLock { channelIds.first } }
        var channelCount: Int { lock.withLock { channelIds.count } }
        var receivedBytes: Data { lock.withLock { received } }
        var credits: [Int] { lock.withLock { creditGrants } }
        var clientSentFIN: Bool { lock.withLock { receivedFIN } }
        var closes: [CloudChannelCloseReason] { lock.withLock { closeReasons } }

        func grant(_ bytes: Int) throws {
            let channelId = try #require(channelId)
            hub.relayToApp(
                machineId: machine.deviceId,
                frame: machine.creditFrame(channelId: channelId, bytes: bytes)
            )
        }

        func send(_ data: Data) throws {
            let channelId = try #require(channelId)
            hub.relayToApp(
                machineId: machine.deviceId,
                sealed: try machine.sealData(channelId: channelId, payload: data)
            )
        }

        func sendFIN() throws {
            try send(Data())
        }

        private func handle(_ envelope: ScriptedCloudHub.RelayEnvelope) {
            guard let appKey = hub.appPublicKey else { return }
            let payload: Data?
            do {
                payload = try machine.receive(envelope.frame, payload: envelope.payload, appPublicKey: appKey)
            } catch {
                return
            }
            switch envelope.frame {
            case let .open(channelId, _, _):
                guard let payload,
                    let open = try? JSONDecoder().decode(OpenPayload.self, from: payload),
                    open.channelType == CloudRelayLoopbackBridge.channelType,
                    open.params.service == CloudRelayLoopbackBridge.service,
                    open.params.version == CloudRelayLoopbackBridge.protocolVersion
                else { return }
                lock.withLock { channelIds.append(channelId) }
                if automaticallyGrantInitialCredit {
                    hub.relayToApp(
                        machineId: machine.deviceId,
                        frame: machine.creditFrame(
                            channelId: channelId,
                            bytes: CloudRelayLoopbackBridge.initialCreditBytes
                        )
                    )
                }
            case let .data(channelId, _):
                guard let payload else { return }
                lock.withLock {
                    if payload.isEmpty {
                        receivedFIN = true
                    } else {
                        received.append(payload)
                    }
                }
                // The real machine returns receive credit after its local TCP
                // socket accepts the bytes.
                hub.relayToApp(
                    machineId: machine.deviceId,
                    frame: machine.creditFrame(
                        channelId: channelId,
                        bytes: envelope.payload.count
                    )
                )
            case let .credit(_, _, bytes):
                lock.withLock { creditGrants.append(bytes) }
            case let .close(_, _, reason):
                lock.withLock { closeReasons.append(reason) }
            }
        }
    }

    private func makeBridge(
        _ scriptedMachine: ScriptedByteMachine
    ) -> (bridge: CloudRelayLoopbackBridge, hub: CloudHubConnection) {
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: InMemoryCloudCredentialStore(token: "session-token"),
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: FakeWebSocketTransport { _ in scriptedMachine.hub.socket },
            readyTimeout: .seconds(2)
        )
        return (
            CloudRelayLoopbackBridge(
                endpoint: CloudRelayEndpoint(
                    hub: hub,
                    machineDeviceId: scriptedMachine.machine.deviceId,
                    machinePublicKey: scriptedMachine.machine.publicKey
                )
            ),
            hub
        )
    }

    @Test("Ciphertext budget calculation matches raw encrypted boxes")
    func ciphertextBudget() {
        // Raw box = plaintext + 16-byte tag; no encoding expansion.
        #expect(CloudRelayLoopbackBridge.sealedByteCount(forPlaintextBytes: 0) == 16)
        #expect(CloudRelayLoopbackBridge.sealedByteCount(forPlaintextBytes: 1) == 17)
        #expect(CloudRelayLoopbackBridge.sealedByteCount(forPlaintextBytes: 65_536) == 65_552)
    }

    @Test("HTTP bytes and keep-alive requests cross one tunnel unchanged")
    func transparentHTTPKeepAlive() async throws {
        let machine = ScriptedByteMachine()
        let (bridge, hub) = makeBridge(machine)
        let client = RawTCPClient(port: try await bridge.start())
        defer {
            client.cancel()
            bridge.stop()
            Task { await hub.shutdown() }
        }
        try await client.connect()

        let requests = Data(
            "POST /one HTTP/1.1\r\nHost: remote\r\nContent-Length: 5\r\n\r\nhelloGET /two HTTP/1.1\r\nHost: remote\r\n\r\n"
                .utf8
        )
        try await client.send(requests)
        #expect(await waitUntil { machine.receivedBytes == requests })
        #expect(machine.channelCount == 1)

        let responses = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\noneHTTP/1.1 201 Created\r\nContent-Length: 3\r\n\r\ntwo".utf8
        )
        try machine.send(responses)
        #expect(try await client.readExactly(responses.count) == responses)
        #expect(
            await waitUntil {
                machine.credits.contains(
                    CloudRelayLoopbackBridge.sealedByteCount(forPlaintextBytes: responses.count)
                )
            }
        )
    }

    @Test("A streaming response is visible before the relay channel ends")
    func incrementalResponse() async throws {
        let machine = ScriptedByteMachine()
        let (bridge, hub) = makeBridge(machine)
        let client = RawTCPClient(port: try await bridge.start())
        defer {
            client.cancel()
            bridge.stop()
            Task { await hub.shutdown() }
        }
        try await client.connect()
        let request = Data("GET /stream.mjpeg HTTP/1.1\r\nHost: remote\r\n\r\n".utf8)
        try await client.send(request)
        #expect(await waitUntil { machine.receivedBytes == request })

        let head = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n\r\n".utf8
        )
        try machine.send(head)
        #expect(try await client.readExactly(head.count) == head)
        #expect(machine.closes.isEmpty)

        let firstFrame = Data("--frame\r\nContent-Length: 4\r\n\r\nJPEG\r\n".utf8)
        try machine.send(firstFrame)
        #expect(try await client.readExactly(firstFrame.count) == firstFrame)
        #expect(machine.closes.isEmpty)
    }

    @Test("Client reads wait for machine credit and FIN propagates both ways")
    func creditAndHalfClose() async throws {
        let machine = ScriptedByteMachine(automaticallyGrantInitialCredit: false)
        let (bridge, hub) = makeBridge(machine)
        let client = RawTCPClient(port: try await bridge.start())
        defer {
            client.cancel()
            bridge.stop()
            Task { await hub.shutdown() }
        }
        try await client.connect()
        let request = Data("GET /finite HTTP/1.1\r\nHost: remote\r\n\r\n".utf8)
        try await client.send(request, isComplete: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(machine.receivedBytes.isEmpty)

        try machine.grant(
            CloudRelayLoopbackBridge.sealedByteCount(
                forPlaintextBytes: CloudRelayLoopbackBridge.maximumChunkBytes
            )
        )
        try #require(await waitUntil { machine.receivedBytes == request })
        try #require(await waitUntil { machine.clientSentFIN })

        let response = Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)
        try machine.send(response)
        try machine.sendFIN()
        #expect(try await client.readExactly(response.count) == response)
        try await client.waitForEOF()
        #expect(await waitUntil { machine.closes == [.done] })
    }

    @Test("Stopping the bridge tears down active local connections")
    func stopTearsDownTunnel() async throws {
        let machine = ScriptedByteMachine()
        let (bridge, hub) = makeBridge(machine)
        let client = RawTCPClient(port: try await bridge.start())
        defer {
            client.cancel()
            Task { await hub.shutdown() }
        }
        try await client.connect()
        try await client.send(Data("GET / HTTP/1.1\r\n\r\n".utf8))
        #expect(await waitUntil { machine.channelCount == 1 })
        bridge.stop()
        await #expect(throws: (any Error).self) {
            _ = try await client.readExactly(1)
        }
    }
}
