import Foundation
import Testing
@testable import ACPKit

/// A handler that records notifications and answers requests from a table.
private final class RecordingHandler: ACPConnectionHandler, @unchecked Sendable {
    let lock = NSLock()
    var notifications: [(String, JSONValue?)] = []
    var requestResult: Result<JSONValue, JSONRPCError>

    init(requestResult: Result<JSONValue, JSONRPCError> = .success(.object([:]))) {
        self.requestResult = requestResult
    }

    func handleRequest(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        requestResult
    }

    func handleNotification(method: String, params: JSONValue?) async {
        lock.withLock { notifications.append((method, params)) }
    }
}

@Suite("ACPConnection")
struct ACPConnectionTests {
    @Test("Correlates a request with its response")
    func requestResponse() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.respond(to: "ping", result: ["pong": true])
        await simulator.start()

        let connection = ACPConnection(transport: transport)
        let handler = RecordingHandler()
        await connection.start(handler: handler)

        let result = try await connection.request("ping", params: ["x": 1])
        #expect(result["pong"] == .bool(true))
    }

    @Test("Throws when the peer returns an error")
    func requestError() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.fail("boom", with: .invalidParams("bad"))
        await simulator.start()

        let connection = ACPConnection(transport: transport)
        await connection.start(handler: RecordingHandler())

        await #expect(throws: ACPError.self) {
            _ = try await connection.request("boom", params: nil)
        }
    }

    @Test("Delivers inbound notifications to the handler")
    func notifications() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.start()

        let connection = ACPConnection(transport: transport)
        let handler = RecordingHandler()
        await connection.start(handler: handler)

        await simulator.sendRawNotification(method: "hello", params: ["a": 1])

        try await pollUntil { handler.lock.withLock { handler.notifications.count == 1 } }
        handler.lock.withLock {
            #expect(handler.notifications.first?.0 == "hello")
        }
    }

    @Test("Services inbound requests using the handler result")
    func inboundRequests() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.start()

        let connection = ACPConnection(transport: transport)
        let handler = RecordingHandler(requestResult: .success(["served": true]))
        await connection.start(handler: handler)

        let response = await simulator.requestClient(method: "fs/read_text_file", id: 100, params: nil)
        #expect(response.result?["served"] == .bool(true))
    }

    @Test("Reports handler failures as JSON-RPC errors")
    func inboundRequestFailure() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.start()

        let connection = ACPConnection(transport: transport)
        let handler = RecordingHandler(requestResult: .failure(.methodNotFound("x")))
        await connection.start(handler: handler)

        let response = await simulator.requestClient(method: "x", id: 101, params: nil)
        #expect(response.error?.code == -32601)
    }

    @Test("Closing fails pending requests")
    func closeFailsPending() async throws {
        let transport = MockTransport()
        // No simulator responding, so the request stays pending.
        let connection = ACPConnection(transport: transport)
        await connection.start(handler: RecordingHandler())

        let task = Task {
            try await connection.request("never", params: nil)
        }
        // Give the request time to register before closing.
        try await Task.sleep(for: .milliseconds(20))
        await connection.close()

        await #expect(throws: ACPError.self) {
            _ = try await task.value
        }
    }

    @Test("Requesting after close throws immediately")
    func requestAfterClose() async throws {
        let transport = MockTransport()
        let connection = ACPConnection(transport: transport)
        await connection.start(handler: RecordingHandler())
        await connection.close()
        await #expect(throws: ACPError.connectionClosed) {
            _ = try await connection.request("x", params: nil)
        }
        await #expect(throws: ACPError.connectionClosed) {
            try await connection.notify("x", params: nil)
        }
    }

    @Test("Transport finishing fails pending requests")
    func transportFinishFailsPending() async throws {
        let transport = MockTransport()
        let connection = ACPConnection(transport: transport)
        await connection.start(handler: RecordingHandler())

        let task = Task { try await connection.request("never", params: nil) }
        try await Task.sleep(for: .milliseconds(20))
        transport.finishIncoming()

        await #expect(throws: (any Error).self) {
            _ = try await task.value
        }
    }
}

/// Polls a synchronous condition until it becomes true or a timeout elapses.
func pollUntil(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition not met before timeout")
}
