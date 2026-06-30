import Foundation
import Testing
@testable import ACPKit

@Suite("Session management")
struct SessionManagementTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try ACPJSON.encoder.encode(value)
        #expect(try ACPJSON.decoder.decode(T.self, from: data) == value)
    }

    @Test("Load/list/delete types round-trip")
    func types() throws {
        try roundTrip(LoadSessionRequest(sessionId: "s", cwd: "/tmp", mcpServers: []))
        try roundTrip(LoadSessionResponse(modes: SessionModeState(currentModeId: "a", availableModes: [SessionMode(id: "a", name: "A")])))
        try roundTrip(SessionInfo(sessionId: "s", cwd: "/tmp", title: "Hi", updatedAt: "2026-06-30T06:32:48.000Z"))
        try roundTrip(ListSessionsRequest(cwd: "/tmp", cursor: "c"))
        try roundTrip(ListSessionsResponse(sessions: [SessionInfo(sessionId: "s", cwd: "/tmp")], nextCursor: "next"))
        try roundTrip(DeleteSessionRequest(sessionId: "s"))
    }

    @Test("Decodes a real session/list response")
    func decodesList() throws {
        let json = """
        {"sessions":[{"sessionId":"019f","cwd":"/Users/x/proj","title":"what does this repo do","updatedAt":"2026-06-30T06:32:48.000Z"}],"nextCursor":null}
        """
        let response = try ACPJSON.decoder.decode(ListSessionsResponse.self, from: Data(json.utf8))
        #expect(response.sessions.count == 1)
        #expect(response.sessions[0].title == "what does this repo do")
        #expect(response.sessions[0].cwd == "/Users/x/proj")
    }

    @Test("Session capabilities decode from presence keys")
    func capabilities() throws {
        let json = #"{"list":{},"resume":{},"delete":{}}"#
        let caps = try ACPJSON.decoder.decode(SessionCapabilities.self, from: Data(json.utf8))
        #expect(caps.list)
        #expect(caps.resume)
        #expect(caps.delete)
        #expect(!caps.close)
        #expect(!caps.fork)
        // Round-trips presence.
        let data = try ACPJSON.encoder.encode(caps)
        #expect(try ACPJSON.decoder.decode(SessionCapabilities.self, from: data) == caps)
    }

    @Test("AgentCapabilities carries session capabilities")
    func agentCaps() throws {
        let json = #"{"loadSession":true,"sessionCapabilities":{"list":{},"resume":{}}}"#
        let caps = try ACPJSON.decoder.decode(AgentCapabilities.self, from: Data(json.utf8))
        #expect(caps.loadSession == true)
        #expect(caps.sessionCapabilities?.list == true)
        #expect(caps.sessionCapabilities?.resume == true)
    }

    @Test("loadSession replays history and listSessions returns sessions")
    func clientLoadAndList() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.respond(to: ACPMethod.sessionLoad, encodable: LoadSessionResponse())
        await simulator.respond(to: ACPMethod.sessionList, encodable: ListSessionsResponse(
            sessions: [SessionInfo(sessionId: "a", cwd: "/x", title: "T")]
        ))
        await simulator.respond(to: ACPMethod.sessionDelete, result: .object([:]))
        await simulator.start()

        let client = ACPClient(transport: transport)
        await client.start()

        _ = try await client.loadSession(LoadSessionRequest(sessionId: "a", cwd: "/x"))
        let list = try await client.listSessions(ListSessionsRequest())
        #expect(list.sessions.first?.title == "T")
        try await client.deleteSession(DeleteSessionRequest(sessionId: "a"))

        let methods = await simulator.requestedMethods()
        #expect(methods.contains(ACPMethod.sessionLoad))
        #expect(methods.contains(ACPMethod.sessionList))
        #expect(methods.contains(ACPMethod.sessionDelete))
    }
}
