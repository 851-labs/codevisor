import ACPKit
import Foundation
import Testing
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

/// Proves the transport seam: the HTTP tunnel runs unchanged over a transport
/// with no hub connection behind it at all — the contract the planned direct
/// LAN/tailnet pipe implements.
@Suite("CloudChannelTransport")
struct CloudChannelTransportTests {
    /// Channel host that hands every client frame to a scripted responder.
    private actor StubChannelHost: CloudChannelHosting {
        var onClientFrame: (@Sendable (String, Data) -> Void)?
        private(set) var closes: [(channelId: String, reason: CloudChannelCloseReason)] = []

        func setClientFrameHandler(_ handler: @escaping @Sendable (String, Data) -> Void) {
            onClientFrame = handler
        }

        func send(channelId: String, plaintext: Data) throws -> Int {
            onClientFrame?(channelId, plaintext)
            return plaintext.count
        }

        func grantCredit(channelId: String, bytes: Int) throws {}

        func closeChannel(_ channelId: String, reason: CloudChannelCloseReason) {
            closes.append((channelId, reason))
        }
    }

    /// A hub-free transport: opening a channel wires the test's responder to
    /// the channel callbacks directly.
    private final class StubTransport: CloudChannelTransport, @unchecked Sendable {
        let machineDeviceId = "stub-machine"
        let host = StubChannelHost()
        private let lock = NSLock()
        private var _openParams: [JSONValue?] = []
        var respond:
            (
                @Sendable (
                    _ channelType: String,
                    _ params: JSONValue?,
                    _ clientFrame: Data,
                    _ onMessage: @escaping @Sendable (Data) -> Void,
                    _ onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
                ) -> Void
            )?

        var openParams: [JSONValue?] { lock.withLock { _openParams } }

        func openChannel(
            channelType: String,
            params: JSONValue?,
            compressed: Bool,
            onMessage: @escaping @Sendable (Data) -> Void,
            onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
        ) async throws -> CloudRelayChannel {
            lock.withLock { _openParams.append(params) }
            let respond = respond
            await host.setClientFrameHandler { _, plaintext in
                respond?(channelType, params, plaintext, onMessage, onClosed)
            }
            return CloudRelayChannel(id: UUID().uuidString, host: host)
        }

        func openFlowControlledChannel(
            channelType: String,
            params: JSONValue?,
            onMessage: @escaping @Sendable (Data, Int) -> Void,
            onCredit: @escaping @Sendable (Int) -> Void,
            onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
        ) async throws -> CloudRelayChannel {
            CloudRelayChannel(id: UUID().uuidString, host: host)
        }
    }

    @Test("The HTTP tunnel completes a round trip over a hub-free transport")
    func httpOverStubTransport() async throws {
        let stub = StubTransport()
        stub.respond = { _, _, clientFrame, onMessage, onClosed in
            struct ClientFrame: Decodable { var kind: String }
            guard let frame = try? JSONDecoder().decode(ClientFrame.self, from: clientFrame),
                frame.kind == "end"
            else { return }
            let respond = { (value: [String: JSONValue]) in
                onMessage(try! JSONEncoder().encode(JSONValue.object(value)))
            }
            respond(["kind": .string("head"), "status": .number(204), "headers": .object([:])])
            respond(["kind": .string("end")])
            onClosed(.done)
        }

        let transport = CloudRelayRequestTransport(endpoint: stub)
        var request = URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/health")!)
        request.httpMethod = "GET"
        let (data, response) = try await transport.data(for: request)

        #expect(response.statusCode == 204)
        #expect(data.isEmpty)
        // The open advertised the request metadata like any transport would.
        #expect(stub.openParams.count == 1)
    }
}
