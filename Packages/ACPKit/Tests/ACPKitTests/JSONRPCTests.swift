import Foundation
import Testing
@testable import ACPKit

@Suite("JSON-RPC messages")
struct JSONRPCTests {
    @Test("Decodes a request (method + id)")
    func decodesRequest() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":7,"method":"ping","params":{"x":1}}"#.utf8)
        let inbound = try JSONRPCInbound(data: data)
        guard case .request(let request) = inbound else { Issue.record("not a request"); return }
        #expect(request.method == "ping")
        #expect(request.id == .number(7))
        #expect(request.params?["x"] == .number(1))
    }

    @Test("Decodes a notification (method, no id)")
    func decodesNotification() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{}}"#.utf8)
        let inbound = try JSONRPCInbound(data: data)
        guard case .notification(let note) = inbound else { Issue.record("not a notification"); return }
        #expect(note.method == "session/update")
    }

    @Test("Decodes a success response")
    func decodesResponse() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":"abc","result":{"ok":true}}"#.utf8)
        let inbound = try JSONRPCInbound(data: data)
        guard case .response(let response) = inbound else { Issue.record("not a response"); return }
        #expect(response.id == .string("abc"))
        #expect(response.result?["ok"] == .bool(true))
        #expect(response.error == nil)
    }

    @Test("Decodes an error response")
    func decodesError() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}}"#.utf8)
        let inbound = try JSONRPCInbound(data: data)
        guard case .response(let response) = inbound else { Issue.record("not a response"); return }
        #expect(response.error?.code == -32601)
        #expect(response.error?.message == "nope")
    }

    @Test("String and number ids round-trip")
    func idRoundTrip() throws {
        for id in [JSONRPCID.number(42), JSONRPCID.string("xyz")] {
            let data = try ACPJSON.encoder.encode(id)
            let decoded = try ACPJSON.decoder.decode(JSONRPCID.self, from: data)
            #expect(decoded == id)
        }
        #expect(JSONRPCID.number(3).description == "3")
        #expect(JSONRPCID.string("a").description == "a")
    }

    @Test("Invalid id type throws")
    func invalidId() {
        #expect(throws: (any Error).self) {
            _ = try ACPJSON.decoder.decode(JSONRPCID.self, from: Data("true".utf8))
        }
    }

    @Test("JSONRPCError factories produce correct codes")
    func errorFactories() {
        #expect(JSONRPCError.parseError().code == -32700)
        #expect(JSONRPCError.invalidRequest().code == -32600)
        #expect(JSONRPCError.methodNotFound("m").code == -32601)
        #expect(JSONRPCError.methodNotFound("m").message.contains("m"))
        #expect(JSONRPCError.invalidParams().code == -32602)
        #expect(JSONRPCError.internalError().code == -32603)
        #expect(JSONRPCError.requestCancelled().code == -32800)
    }
}
