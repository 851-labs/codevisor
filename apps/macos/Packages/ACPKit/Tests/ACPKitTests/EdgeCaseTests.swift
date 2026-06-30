import Foundation
import Testing
@testable import ACPKit

private final class NoopHandler: ACPConnectionHandler {
    func handleRequest(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        .success(.object([:]))
    }
    func handleNotification(method: String, params: JSONValue?) async {}
}

@Suite("Edge cases")
struct EdgeCaseTests {
    @Test("Malformed inbound data is ignored and the connection still works")
    func malformedData() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.respond(to: "ping", result: ["ok": true])
        await simulator.start()

        let connection = ACPConnection(transport: transport)
        await connection.start(handler: NoopHandler())

        // Inject garbage that is not valid JSON-RPC; it must be dropped silently.
        transport.emit(Data("this is not json".utf8))

        let result = try await connection.request("ping", params: nil)
        #expect(result["ok"] == .bool(true))
    }

    @Test("Responses with unknown or string ids are ignored")
    func strayResponses() async throws {
        let transport = MockTransport()
        let connection = ACPConnection(transport: transport)
        await connection.start(handler: NoopHandler())

        // A response to an id that was never requested.
        let stray = JSONRPCResponse(id: .number(999), result: .object([:]), error: nil)
        transport.emit(try ACPJSON.encoder.encode(stray))
        // A response with a string id (clients only issue numeric ids).
        let stringId = JSONRPCResponse(id: .string("nope"), result: .object([:]), error: nil)
        transport.emit(try ACPJSON.encoder.encode(stringId))

        // Connection remains usable.
        await connection.close()
    }

    @Test("Double close is safe")
    func doubleClose() async throws {
        let transport = MockTransport()
        let connection = ACPConnection(transport: transport)
        await connection.start(handler: NoopHandler())
        await connection.close()
        await connection.close() // no-op
    }

    @Test("Starting twice does not restart the read loop")
    func doubleStart() async throws {
        let transport = MockTransport()
        let connection = ACPConnection(transport: transport)
        await connection.start(handler: NoopHandler())
        await connection.start(handler: NoopHandler())
        await connection.close()
    }

    @Test("MockTransport emits encodable values and rejects sends after close")
    func mockTransport() async throws {
        let transport = MockTransport()
        try transport.emit(PromptResponse(stopReason: .endTurn))

        var received: Data?
        for try await data in transport.incoming {
            received = data
            break
        }
        #expect(received != nil)

        transport.close()
        await #expect(throws: (any Error).self) {
            try await transport.send(Data("x".utf8))
        }
    }

    @Test("ACPError equality")
    func acpErrorEquality() {
        #expect(ACPError.connectionClosed == ACPError.connectionClosed)
        #expect(ACPError.malformedResponse == ACPError.malformedResponse)
        #expect(ACPError.rpc(.invalidParams("a")) == ACPError.rpc(.invalidParams("a")))
        #expect(ACPError.connectionClosed != ACPError.malformedResponse)
    }
}
