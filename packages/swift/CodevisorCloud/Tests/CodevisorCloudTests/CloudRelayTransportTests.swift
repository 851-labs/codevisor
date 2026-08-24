import Foundation
import Testing
import ACPKit
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

@Suite("CloudRelayTransport")
struct CloudRelayTransportTests {
    /// Scripts the machine end of "http" channels: decrypts the open, gathers
    /// body chunks until `end`, then answers head → chunks → end → close.
    private final class ScriptedHttpMachine: @unchecked Sendable {
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

        private struct OpenPayload: Decodable {
            struct Params: Decodable {
                var method: String
                var path: String
                var headers: [String: String]
            }

            var channelType: String
            var params: Params
        }

        private struct ClientFrame: Decodable {
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

        let machine = ScriptedRelayMachine()
        let scripted: ScriptedCloudHub
        var respond: (@Sendable (ReceivedRequest) -> ScriptedResponse)?
        private let lock = NSLock()
        private var requestsByChannel: [String: (params: OpenPayload.Params, body: Data)] = [:]
        private(set) var completedRequests: [ReceivedRequest] = []

        init() {
            scripted = ScriptedCloudHub(machines: [machine.presence])
            scripted.onRelay = { [weak self] envelope in
                self?.handle(envelope)
            }
        }

        private func handle(_ envelope: ScriptedCloudHub.RelayEnvelope) {
            guard let appKey = scripted.appPublicKey else { return }
            guard let payload = try? machine.receive(envelope.frame, payload: envelope.payload, appPublicKey: appKey)
            else { return }
            let channelId = envelope.frame.channelId
            switch envelope.frame {
            case .open:
                guard let open = try? JSONDecoder().decode(OpenPayload.self, from: payload),
                    open.channelType == "http"
                else { return }
                lock.withLock { requestsByChannel[channelId] = (open.params, Data()) }
            case .data:
                guard let frame = try? JSONDecoder().decode(ClientFrame.self, from: payload) else { return }
                switch frame.kind {
                case "chunk":
                    guard let encoded = frame.data,
                        let chunk = CloudChannelCrypto.base64URLDecode(encoded)
                    else { return }
                    lock.withLock { requestsByChannel[channelId]?.body.append(chunk) }
                case "end":
                    finish(channelId: channelId)
                default:
                    break
                }
            case .credit, .close:
                break
            }
        }

        private func finish(channelId: String) {
            guard let pending = lock.withLock({ requestsByChannel.removeValue(forKey: channelId) })
            else { return }
            let request = ReceivedRequest(
                method: pending.params.method,
                path: pending.params.path,
                headers: pending.params.headers,
                body: pending.body
            )
            lock.withLock { completedRequests.append(request) }
            guard let response = respond?(request) else { return }
            let encoder = JSONEncoder()
            func sendJSON(_ value: some Encodable) {
                guard let data = try? encoder.encode(value),
                    let sealed = try? machine.sealData(channelId: channelId, payload: data)
                else { return }
                scripted.relayToApp(machineId: machine.deviceId, sealed: sealed)
            }
            if response.status > 0 {
                sendJSON(HeadFrame(status: response.status, headers: response.headers))
                for chunk in response.bodyChunks {
                    sendJSON(BodyFrame(kind: "chunk", data: CloudChannelCrypto.base64URLEncode(chunk)))
                }
                sendJSON(BodyFrame(kind: "end", data: nil))
            }
            scripted.relayToApp(
                machineId: machine.deviceId,
                frame: machine.closeFrame(channelId: channelId, reason: response.closeReason)
            )
        }
    }

    private func makeEndpoint(
        _ scriptedMachine: ScriptedHttpMachine
    ) -> (endpoint: CloudRelayEndpoint, hub: CloudHubConnection) {
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
        return (endpoint, hub)
    }

    /// Scripts the machine end of "ws" channels: remembers accepted opens and
    /// lets the test push sealed frames toward the app.
    private final class ScriptedWsMachine: @unchecked Sendable {
        let machine = ScriptedRelayMachine()
        let scripted: ScriptedCloudHub
        private let lock = NSLock()
        private var _openChannelIds: [String] = []

        init() {
            scripted = ScriptedCloudHub(machines: [machine.presence])
            scripted.onRelay = { [weak self] envelope in
                guard let self, let appKey = self.scripted.appPublicKey else { return }
                guard
                    (try? self.machine.receive(envelope.frame, payload: envelope.payload, appPublicKey: appKey)) != nil
                else { return }
                if case .open = envelope.frame {
                    self.lock.withLock { self._openChannelIds.append(envelope.frame.channelId) }
                }
            }
        }

        var openChannelId: String? { lock.withLock { _openChannelIds.first } }

        func push(_ json: String) {
            guard let channelId = openChannelId,
                let sealed = try? machine.sealData(channelId: channelId, payload: Data(json.utf8))
            else { return }
            scripted.relayToApp(machineId: machine.deviceId, sealed: sealed)
        }
    }

    private static func text(_ message: ServerWebSocketMessage) -> String? {
        if case let .string(value) = message { return value }
        return nil
    }

    private static func binary(_ message: ServerWebSocketMessage) -> Data? {
        if case let .data(value) = message { return value }
        return nil
    }

    @Test("Chunked ws frames reassemble into one message; unknown kinds are skipped")
    func wsChunkReassembly() async throws {
        let scriptedMachine = ScriptedWsMachine()
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
        let socket = CloudRelayWebSocketTransport(endpoint: endpoint).connect(
            URLRequest(url: URL(string: "https://relay.invalid/v1/sessions/x/events/socket")!),
            maximumMessageSize: 1 << 20
        )
        let base64 = { (piece: String) in CloudChannelCrypto.base64URLEncode(Data(piece.utf8)) }

        let first = Task { try await socket.receive() }
        #expect(await waitUntil { scriptedMachine.openChannelId != nil })
        scriptedMachine.push(#"{"kind":"part","data":"\#(base64("hello, "))"}"#)
        // Unknown future kinds are skipped, never spliced into a message.
        scriptedMachine.push(#"{"kind":"future-frame","data":"ignored"}"#)
        scriptedMachine.push(#"{"kind":"text-end","data":"\#(base64("chunked world"))"}"#)
        #expect(Self.text(try await first.value) == "hello, chunked world")

        // Plain frames pass through untouched after a chunked message.
        let second = Task { try await socket.receive() }
        scriptedMachine.push(#"{"kind":"text","data":"plain"}"#)
        #expect(Self.text(try await second.value) == "plain")

        // Binary messages reassemble the same way.
        let third = Task { try await socket.receive() }
        scriptedMachine.push(#"{"kind":"part","data":"\#(base64("01"))"}"#)
        scriptedMachine.push(#"{"kind":"binary-end","data":"\#(base64("23"))"}"#)
        #expect(Self.binary(try await third.value) == Data("0123".utf8))

        socket.cancel(with: .goingAway, reason: nil)
        await hub.shutdown()
    }

    @Test("HTTP requests round-trip: method, path+query, headers, chunked bodies")
    func httpRoundTrip() async throws {
        let scriptedMachine = ScriptedHttpMachine()
        let responseBody = Data("{\"ok\":true,\"version\":\"1.2.3\"}".utf8)
        scriptedMachine.respond = { request in
            ScriptedHttpMachine.ScriptedResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                // Two chunks prove reassembly order.
                bodyChunks: [responseBody.prefix(10), responseBody.dropFirst(10)]
            )
        }
        let (endpoint, hub) = makeEndpoint(scriptedMachine)
        let transport = CloudRelayRequestTransport(endpoint: endpoint)

        // A body bigger than one chunk exercises request-side chunking.
        let requestBody = Data((0..<(CloudRelayRequestTransport.chunkSize + 1000)).map { UInt8($0 % 251) })
        var request = URLRequest(
            url: URL(string: "https://cloud-relay.invalid/v1/health?probe=1")!
        )
        request.httpMethod = "POST"
        request.httpBody = requestBody
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.data(for: request)

        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(data == responseBody)
        let received = try #require(scriptedMachine.completedRequests.first)
        #expect(received.method == "POST")
        #expect(received.path == "/v1/health?probe=1")
        #expect(received.headers["Authorization"] == "Bearer secret")
        #expect(received.body == requestBody)
        await hub.shutdown()
    }

    @Test("A rejected close surfaces as an error")
    func rejectedRequest() async throws {
        let scriptedMachine = ScriptedHttpMachine()
        scriptedMachine.respond = { _ in
            ScriptedHttpMachine.ScriptedResponse(
                status: 0, headers: [:], bodyChunks: [], closeReason: .rejected
            )
        }
        let (endpoint, hub) = makeEndpoint(scriptedMachine)
        let transport = CloudRelayRequestTransport(endpoint: endpoint)

        await #expect(throws: CloudRelayTransportError.channelClosed(.rejected)) {
            _ = try await transport.data(
                for: URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/info")!)
            )
        }
        await hub.shutdown()
    }

    @Test("A request whose channel never answers times out instead of hanging")
    func requestTimesOut() async throws {
        let scriptedMachine = ScriptedHttpMachine()
        // respond stays nil: the machine accepts the open but never replies.
        let (endpoint, hub) = makeEndpoint(scriptedMachine)
        let transport = CloudRelayRequestTransport(endpoint: endpoint, timeout: .milliseconds(250))

        await #expect(throws: CloudRelayTransportError.timedOut) {
            _ = try await transport.data(
                for: URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/info")!)
            )
        }
        await hub.shutdown()
    }

    @Test("A real server client works end-to-end over the relay transport")
    func serverClientOverRelay() async throws {
        let scriptedMachine = ScriptedHttpMachine()
        scriptedMachine.respond = { request in
            guard request.path == "/v1/info" else {
                return ScriptedHttpMachine.ScriptedResponse(
                    status: 404, headers: [:], bodyChunks: [Data("{}".utf8)]
                )
            }
            let info = Data(
                """
                {"id":"m1","name":"Relay Mac","kind":"remote","version":"9.9.9",
                 "platform":"darwin","bindHost":"127.0.0.1","cloudDeviceId":"machine-1"}
                """.utf8)
            return ScriptedHttpMachine.ScriptedResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                bodyChunks: [info]
            )
        }
        let (endpoint, hub) = makeEndpoint(scriptedMachine)
        let client = CodevisorServerClient(
            config: CodevisorServerConfig(
                baseURL: CodevisorMachine.cloudPlaceholderBaseURL,
                requestTransport: CloudRelayRequestTransport(endpoint: endpoint),
                webSocketTransport: CloudRelayWebSocketTransport(endpoint: endpoint)
            ))

        let info = try await client.info()
        #expect(info.name == "Relay Mac")
        #expect(info.cloudDeviceId == "machine-1")
        await hub.shutdown()
    }
}
