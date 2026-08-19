import Foundation
import Network
import Testing
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

/// A hand-rolled TCP client for exercising the bridge's HTTP/1.1 connection
/// semantics directly — URLSession hides connection reuse, so keep-alive
/// assertions need the raw socket.
private final class RawHTTPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "raw-http-client")
    private var buffer = Data()

    init(port: UInt16) {
        connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    /// A claim-once flag for the connect continuation (state callbacks can
    /// fire again after `.ready`).
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

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
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

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: Data(text.utf8),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    /// One received chunk, nil at EOF.
    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    struct Response {
        var status: Int
        /// Lowercased header names.
        var headers: [String: String]
        var body: Data
    }

    /// Reads exactly one HTTP response (head + Content-Length body), leaving
    /// any following bytes buffered for the next read.
    func readResponse() async throws -> Response {
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.firstRange(of: terminator) == nil {
            guard let chunk = try await receiveChunk() else { throw URLError(.badServerResponse) }
            buffer.append(chunk)
        }
        let range = buffer.firstRange(of: terminator)!
        let headText = String(decoding: buffer.subdata(in: buffer.startIndex..<range.lowerBound), as: UTF8.self)
        buffer = buffer.subdata(in: range.upperBound..<buffer.endIndex)
        var lines = headText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let status = Int(statusLine.split(separator: " ")[1]) ?? 0
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        while buffer.count < contentLength {
            guard let chunk = try await receiveChunk() else { throw URLError(.badServerResponse) }
            buffer.append(chunk)
        }
        let body = buffer.prefix(contentLength)
        buffer = buffer.subdata(in: buffer.startIndex.advanced(by: contentLength)..<buffer.endIndex)
        return Response(status: status, headers: headers, body: Data(body))
    }

    /// True when the server closes the connection (EOF) within the timeout.
    func waitForEOF(timeout: Duration = .seconds(5)) async -> Bool {
        let read = Task { () -> Bool in
            while true {
                guard let chunk = try await self.receiveChunk() else { return true }
                self.buffer.append(chunk)
            }
        }
        defer { read.cancel() }
        let deadline = Task {
            try await Task.sleep(for: timeout)
            read.cancel()
        }
        defer { deadline.cancel() }
        return (try? await read.value) ?? false
    }

    func cancel() {
        connection.cancel()
    }
}

@Suite("CloudRelayLoopbackBridge")
struct CloudRelayLoopbackBridgeTests {
    /// Scripts the machine end of both generic relay channel types, like the
    /// real cloud-bridge: "http" channels answer scripted responses, "ws"
    /// channels echo every frame back (text frames gain an "echo:" prefix to
    /// prove they crossed the machine side).
    private final class ScriptedLoopbackMachine: @unchecked Sendable {
        struct ReceivedRequest {
            var method: String
            var path: String
            var headers: [String: String]
            var body: Data
        }

        struct ScriptedResponse {
            var status: Int
            var headers: [String: String]
            var bodyChunks: [Data]
            var closeReason: CloudChannelCloseReason = .done
        }

        private struct HttpOpenPayload: Decodable {
            struct Params: Decodable {
                var method: String
                var path: String
                var headers: [String: String]
            }

            var channelType: String
            var params: Params
        }

        private struct WsOpenPayload: Decodable {
            struct Params: Decodable {
                var path: String
            }

            var channelType: String
            var params: Params
        }

        private struct ChannelTypeProbe: Decodable {
            var channelType: String
        }

        private struct HttpClientFrame: Decodable {
            var kind: String
            var data: String?
        }

        private struct HeadFrame: Encodable {
            var kind = "head"
            var status: Int
            var headers: [String: String]
        }

        private struct BodyFrame: Encodable {
            var kind: String
            var data: String?
        }

        private struct WsFrame: Codable {
            var kind: String
            var data: String
        }

        let machine = ScriptedRelayMachine()
        let scripted: ScriptedCloudHub
        var respond: (@Sendable (ReceivedRequest) -> ScriptedResponse)?
        private let lock = NSLock()
        private var httpChannels: [String: (params: HttpOpenPayload.Params, body: Data)] = [:]
        private var wsChannels: Set<String> = []
        private(set) var completedRequests: [ReceivedRequest] = []
        private(set) var wsPaths: [String] = []
        private(set) var wsClosedChannels: [CloudChannelCloseReason] = []

        init() {
            scripted = ScriptedCloudHub(machines: [machine.presence])
            scripted.onRelay = { [weak self] envelope in
                self?.handle(envelope)
            }
        }

        private func sendJSON(_ value: some Encodable, channelId: String) {
            guard let data = try? JSONEncoder().encode(value),
                let frame = try? machine.sealData(channelId: channelId, payload: data)
            else { return }
            scripted.relayToApp(machineId: machine.deviceId, frame: frame)
        }

        private func handle(_ envelope: ScriptedCloudHub.RelayEnvelope) {
            guard let appKey = scripted.appPublicKey else { return }
            // Close frames decrypt to no payload; a throw means a bad frame.
            let payload: Data?
            do {
                payload = try machine.receive(envelope.frame, appPublicKey: appKey)
            } catch {
                return
            }
            let channelId = envelope.frame.channelId
            switch envelope.frame {
            case .open:
                guard let payload,
                    let probe = try? JSONDecoder().decode(ChannelTypeProbe.self, from: payload)
                else { return }
                switch probe.channelType {
                case "http":
                    guard let open = try? JSONDecoder().decode(HttpOpenPayload.self, from: payload) else { return }
                    lock.withLock { httpChannels[channelId] = (open.params, Data()) }
                case "ws":
                    guard let open = try? JSONDecoder().decode(WsOpenPayload.self, from: payload) else { return }
                    lock.withLock {
                        _ = wsChannels.insert(channelId)
                        wsPaths.append(open.params.path)
                    }
                default:
                    break
                }
            case .data:
                guard let payload else { return }
                if lock.withLock({ wsChannels.contains(channelId) }) {
                    handleWsData(payload, channelId: channelId)
                } else {
                    handleHttpData(payload, channelId: channelId)
                }
            case let .close(_, _, reason):
                if lock.withLock({ wsChannels.remove(channelId) }) != nil {
                    lock.withLock { wsClosedChannels.append(reason) }
                }
            case .credit:
                break
            }
        }

        private func handleWsData(_ payload: Data, channelId: String) {
            guard let frame = try? JSONDecoder().decode(WsFrame.self, from: payload) else { return }
            if frame.kind == "text" {
                sendJSON(WsFrame(kind: "text", data: "echo:\(frame.data)"), channelId: channelId)
            } else {
                sendJSON(frame, channelId: channelId)
            }
        }

        private func handleHttpData(_ payload: Data, channelId: String) {
            guard let frame = try? JSONDecoder().decode(HttpClientFrame.self, from: payload) else { return }
            switch frame.kind {
            case "chunk":
                guard let encoded = frame.data,
                    let chunk = CloudChannelCrypto.base64URLDecode(encoded)
                else { return }
                lock.withLock { httpChannels[channelId]?.body.append(chunk) }
            case "end":
                finish(channelId: channelId)
            default:
                break
            }
        }

        private func finish(channelId: String) {
            guard let pending = lock.withLock({ httpChannels.removeValue(forKey: channelId) })
            else { return }
            let request = ReceivedRequest(
                method: pending.params.method,
                path: pending.params.path,
                headers: pending.params.headers,
                body: pending.body
            )
            lock.withLock { completedRequests.append(request) }
            guard let response = respond?(request) else { return }
            if response.status > 0 {
                sendJSON(HeadFrame(status: response.status, headers: response.headers), channelId: channelId)
                for chunk in response.bodyChunks {
                    sendJSON(
                        BodyFrame(kind: "chunk", data: CloudChannelCrypto.base64URLEncode(chunk)),
                        channelId: channelId
                    )
                }
                sendJSON(BodyFrame(kind: "end", data: nil), channelId: channelId)
            }
            scripted.relayToApp(
                machineId: machine.deviceId,
                frame: machine.closeFrame(channelId: channelId, reason: response.closeReason)
            )
        }
    }

    private func makeBridge(
        _ scriptedMachine: ScriptedLoopbackMachine
    ) -> (bridge: CloudRelayLoopbackBridge, hub: CloudHubConnection) {
        let hub = CloudHubConnection(
            serverURL: URL(string: "https://cloud.example.com")!,
            credentialStore: InMemoryCloudCredentialStore(token: "session-token"),
            deviceName: "Test App",
            deviceOS: "macOS",
            webSocketTransport: FakeWebSocketTransport { _ in scriptedMachine.scripted.socket },
            readyTimeout: .seconds(2)
        )
        let endpoint = CloudRelayEndpoint(
            hub: hub,
            machineDeviceId: scriptedMachine.machine.deviceId,
            machinePublicKey: scriptedMachine.machine.publicKey
        )
        return (CloudRelayLoopbackBridge(endpoint: endpoint), hub)
    }

    @Test("Sec-WebSocket-Accept matches the RFC 6455 vector")
    func handshakeAcceptVector() {
        #expect(
            CloudRelayLoopbackBridge.webSocketAccept(forKey: "dGhlIHNhbXBsZSBub25jZQ==")
                == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    @Test("Plain HTTP round-trips through the loopback listener onto the relay")
    func httpRoundTrip() async throws {
        let scriptedMachine = ScriptedLoopbackMachine()
        let responseBody = Data("{\"ok\":true}".utf8)
        scriptedMachine.respond = { _ in
            ScriptedLoopbackMachine.ScriptedResponse(
                status: 201,
                headers: ["Content-Type": "application/json", "X-Custom": "yes"],
                bodyChunks: [responseBody.prefix(4), responseBody.dropFirst(4)]
            )
        }
        let (bridge, hub) = makeBridge(scriptedMachine)
        let port = try await bridge.start()
        defer {
            bridge.stop()
            Task { await hub.shutdown() }
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/terminals?probe=1")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"sessionId\":\"abc\"}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer machine-token", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 201)
        #expect(http.value(forHTTPHeaderField: "X-Custom") == "yes")
        #expect(data == responseBody)

        let received = try #require(scriptedMachine.completedRequests.first)
        #expect(received.method == "POST")
        #expect(received.path == "/v1/terminals?probe=1")
        #expect(received.body == Data("{\"sessionId\":\"abc\"}".utf8))
        // Headers cross the loopback hop verbatim — including Authorization,
        // which only the machine side may strip (its loopback replay is
        // token-exempt).
        #expect(received.headers["Authorization"] == "Bearer machine-token")
        #expect(received.headers["Content-Type"] == "application/json")
    }

    @Test("A dead relay answers 502 instead of hanging the socket")
    func relayFailureAnswers502() async throws {
        let scriptedMachine = ScriptedLoopbackMachine()
        scriptedMachine.respond = { _ in
            ScriptedLoopbackMachine.ScriptedResponse(
                status: 0, headers: [:], bodyChunks: [], closeReason: .rejected
            )
        }
        let (bridge, hub) = makeBridge(scriptedMachine)
        let port = try await bridge.start()
        defer {
            bridge.stop()
            Task { await hub.shutdown() }
        }

        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/v1/info")!
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
    }

    @Test("WebSocket upgrade bridges frames both ways over a ws relay channel")
    func webSocketEcho() async throws {
        let scriptedMachine = ScriptedLoopbackMachine()
        let (bridge, hub) = makeBridge(scriptedMachine)
        let port = try await bridge.start()
        defer {
            bridge.stop()
            Task { await hub.shutdown() }
        }

        let task = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/v1/terminals/t1/ws?lastOutputSeq=0")!
        )
        task.resume()

        // Text: the scripted machine prefixes, proving the frame crossed the
        // relay (masked client frame in, unmasked server frame out).
        try await task.send(.string("relay-ok"))
        guard case let .string(text) = try await task.receive() else {
            Issue.record("Expected a text echo frame")
            return
        }
        #expect(text == "echo:relay-ok")

        // Binary: byte-exact round-trip through b64url relay frames.
        let payload = Data((0..<300).map { UInt8($0 % 251) })
        try await task.send(.data(payload))
        guard case let .data(echoed) = try await task.receive() else {
            Issue.record("Expected a binary echo frame")
            return
        }
        #expect(echoed == payload)

        // The channel carried the exact upgrade path, query included.
        #expect(scriptedMachine.wsPaths == ["/v1/terminals/t1/ws?lastOutputSeq=0"])

        task.cancel(with: .normalClosure, reason: nil)
        // Client close reaches the machine as a relay channel close("done").
        let closed = await waitUntil {
            !scriptedMachine.wsClosedChannels.isEmpty
        }
        #expect(closed)
        #expect(scriptedMachine.wsClosedChannels == [.done])
    }

    @Test("Keep-alive serves sequential requests on one TCP connection")
    func keepAliveSequentialRequests() async throws {
        let scriptedMachine = ScriptedLoopbackMachine()
        scriptedMachine.respond = { request in
            ScriptedLoopbackMachine.ScriptedResponse(
                status: 200,
                headers: ["Content-Type": "text/plain"],
                bodyChunks: [Data("answer for \(request.path)".utf8)]
            )
        }
        let (bridge, hub) = makeBridge(scriptedMachine)
        let port = try await bridge.start()
        let client = RawHTTPClient(port: port)
        defer {
            client.cancel()
            bridge.stop()
            Task { await hub.shutdown() }
        }
        try await client.connect()

        // First request carries a body — the keep-alive loop must consume it
        // exactly so the second head parses from the right byte.
        try await client.send(
            "POST /v1/first HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nhello"
        )
        let first = try await client.readResponse()
        #expect(first.status == 200)
        #expect(first.headers["connection"] == "keep-alive")
        #expect(first.body == Data("answer for /v1/first".utf8))

        try await client.send("GET /v1/second HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let second = try await client.readResponse()
        #expect(second.status == 200)
        #expect(second.headers["connection"] == "keep-alive")
        #expect(second.body == Data("answer for /v1/second".utf8))

        #expect(scriptedMachine.completedRequests.map(\.path) == ["/v1/first", "/v1/second"])
        #expect(scriptedMachine.completedRequests.first?.body == Data("hello".utf8))
    }

    @Test("Connection: close is honored — respond once, then EOF")
    func connectionCloseHonored() async throws {
        let scriptedMachine = ScriptedLoopbackMachine()
        scriptedMachine.respond = { _ in
            ScriptedLoopbackMachine.ScriptedResponse(
                status: 200, headers: [:], bodyChunks: [Data("bye".utf8)]
            )
        }
        let (bridge, hub) = makeBridge(scriptedMachine)
        let port = try await bridge.start()
        let client = RawHTTPClient(port: port)
        defer {
            client.cancel()
            bridge.stop()
            Task { await hub.shutdown() }
        }
        try await client.connect()

        try await client.send(
            "GET /v1/info HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        )
        let response = try await client.readResponse()
        #expect(response.status == 200)
        #expect(response.headers["connection"] == "close")
        #expect(response.body == Data("bye".utf8))
        let closed = await client.waitForEOF()
        #expect(closed)
    }

    @Test("A WebSocket upgrade still works after HTTP requests on other connections")
    func webSocketAfterHTTPTraffic() async throws {
        let scriptedMachine = ScriptedLoopbackMachine()
        scriptedMachine.respond = { _ in
            ScriptedLoopbackMachine.ScriptedResponse(
                status: 204, headers: [:], bodyChunks: []
            )
        }
        let (bridge, hub) = makeBridge(scriptedMachine)
        let port = try await bridge.start()
        defer {
            bridge.stop()
            Task { await hub.shutdown() }
        }

        // Plain HTTP traffic first (its own connections)…
        for path in ["/v1/one", "/v1/two"] {
            let (_, response) = try await URLSession.shared.data(
                from: URL(string: "http://127.0.0.1:\(port)\(path)")!
            )
            #expect((response as? HTTPURLResponse)?.statusCode == 204)
        }

        // …then a WebSocket upgrade on a fresh connection still bridges.
        let task = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/v1/terminals/t9/ws")!
        )
        task.resume()
        try await task.send(.string("still-alive"))
        guard case let .string(text) = try await task.receive() else {
            Issue.record("Expected a text echo frame")
            return
        }
        #expect(text == "echo:still-alive")
        task.cancel(with: .normalClosure, reason: nil)
    }
}
