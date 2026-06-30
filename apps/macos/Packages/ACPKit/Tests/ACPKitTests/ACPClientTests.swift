import Foundation
import Testing
@testable import ACPKit

/// A configurable client delegate for exercising agent-to-client requests.
private final class TestDelegate: ACPClientDelegate, @unchecked Sendable {
    var permissionOutcome: RequestPermissionOutcome = .selected(optionId: "ok")
    var fileContents: String = "file body"
    var writtenPaths: [String] = []
    let lock = NSLock()

    func requestPermission(_ request: RequestPermissionRequest) async -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: permissionOutcome)
    }

    func readTextFile(_ request: ReadTextFileRequest) async throws -> ReadTextFileResponse {
        ReadTextFileResponse(content: fileContents)
    }

    func writeTextFile(_ request: WriteTextFileRequest) async throws {
        lock.withLock { writtenPaths.append(request.path) }
    }

    func createTerminal(_ request: CreateTerminalRequest) async throws -> CreateTerminalResponse {
        CreateTerminalResponse(terminalId: "term-1")
    }

    func terminalOutput(_ request: TerminalRequest) async throws -> TerminalOutputResponse {
        TerminalOutputResponse(output: "hello", truncated: false)
    }

    func waitForTerminalExit(_ request: TerminalRequest) async throws -> WaitForExitResponse {
        WaitForExitResponse(exitCode: 0)
    }

    func releaseTerminal(_ request: TerminalRequest) async throws {
        lock.withLock { writtenPaths.append("released:\(request.terminalId)") }
    }

    func killTerminal(_ request: TerminalRequest) async throws {
        lock.withLock { writtenPaths.append("killed:\(request.terminalId)") }
    }
}

/// A delegate whose file read throws a non-JSONRPC error.
private struct GenericFailure: Error {}
private final class ThrowingDelegate: ACPClientDelegate {
    func readTextFile(_ request: ReadTextFileRequest) async throws -> ReadTextFileResponse {
        throw GenericFailure()
    }
}

/// A delegate that uses every default protocol implementation.
private final class DefaultDelegate: ACPClientDelegate {}

@Suite("ACPClient")
struct ACPClientTests {
    @Test("initialize negotiates protocol version")
    func initialize() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.respond(to: ACPMethod.initialize, encodable: InitializeResponse(
            protocolVersion: 1,
            agentCapabilities: AgentCapabilities(loadSession: true)
        ))
        await simulator.start()

        let client = ACPClient(transport: transport)
        await client.start()

        let response = try await client.initialize(InitializeRequest(protocolVersion: .acpProtocolVersion))
        #expect(response.protocolVersion == 1)
        #expect(response.agentCapabilities?.loadSession == true)
        let methods = await simulator.requestedMethods()
        #expect(methods == [ACPMethod.initialize])
    }

    @Test("newSession returns a session id and prompt yields a stop reason")
    func sessionAndPrompt() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.respond(to: ACPMethod.sessionNew, encodable: NewSessionResponse(sessionId: "sess-1"))
        await simulator.respond(to: ACPMethod.sessionPrompt, encodable: PromptResponse(stopReason: .endTurn))
        await simulator.start()

        let client = ACPClient(transport: transport)
        await client.start()

        let session = try await client.newSession(NewSessionRequest(cwd: "/tmp"))
        #expect(session.sessionId == "sess-1")
        let result = try await client.prompt(PromptRequest(sessionId: "sess-1", prompt: [.text("hi")]))
        #expect(result.stopReason == .endTurn)
    }

    @Test("Session updates stream in arrival order")
    func updatesStream() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.respond(to: ACPMethod.sessionNew, encodable: NewSessionResponse(sessionId: "s"))
        await simulator.start()

        let client = ACPClient(transport: transport)
        await client.start()
        _ = try await client.newSession(NewSessionRequest(cwd: "/tmp"))
        let stream = await client.updates(for: "s")

        // Push an interleaved sequence: text -> tool -> text.
        await simulator.sendUpdate(SessionNotification(sessionId: "s", update: .agentMessageChunk(.text("one"))))
        await simulator.sendUpdate(SessionNotification(sessionId: "s", update: .toolCall(ToolCall(toolCallId: "t", title: "Run"))))
        await simulator.sendUpdate(SessionNotification(sessionId: "s", update: .agentMessageChunk(.text("two"))))

        var collected: [SessionUpdate] = []
        for await update in stream {
            collected.append(update)
            if collected.count == 3 { break }
        }
        #expect(collected.count == 3)
        if case .agentMessageChunk(let block) = collected[0] { #expect(block.textValue == "one") } else { Issue.record("order") }
        if case .toolCall = collected[1] {} else { Issue.record("expected tool call second") }
        if case .agentMessageChunk(let block) = collected[2] { #expect(block.textValue == "two") } else { Issue.record("order") }
    }

    @Test("cancel emits a session/cancel notification")
    func cancel() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.start()

        let client = ACPClient(transport: transport)
        await client.start()
        try await client.cancel(sessionId: "s")

        var sawCancel = false
        for _ in 0..<200 {
            let notifications = await simulator.receivedNotifications
            if notifications.contains(where: { $0.method == ACPMethod.sessionCancel }) {
                sawCancel = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(sawCancel)
    }

    @Test("setMode and authenticate send requests")
    func setModeAndAuth() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.respond(to: ACPMethod.sessionSetMode, result: .object([:]))
        await simulator.respond(to: ACPMethod.authenticate, result: .object([:]))
        await simulator.start()

        let client = ACPClient(transport: transport)
        await client.start()
        try await client.setMode(SetSessionModeRequest(sessionId: "s", modeId: "deep"))
        try await client.authenticate(AuthenticateRequest(methodId: "oauth"))
        let methods = await simulator.requestedMethods()
        #expect(methods.contains(ACPMethod.sessionSetMode))
        #expect(methods.contains(ACPMethod.authenticate))
    }

    @Test("setConfigOption returns the updated option set")
    func setConfigOption() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        let option = SessionConfigOption(id: "model", name: "Model", currentValue: "gpt-5.4",
                                         options: [SessionConfigSelectOption(value: "gpt-5.4", name: "GPT-5.4")])
        await simulator.respond(to: ACPMethod.sessionSetConfigOption, encodable: SetSessionConfigOptionResponse(configOptions: [option]))
        await simulator.start()

        let client = ACPClient(transport: transport)
        await client.start()
        let response = try await client.setConfigOption(SetSessionConfigOptionRequest(sessionId: "s", configId: "model", value: "gpt-5.4"))
        #expect(response.configOptions.first?.currentValue == "gpt-5.4")
        let methods = await simulator.requestedMethods()
        #expect(methods.contains(ACPMethod.sessionSetConfigOption))
    }

    @Test("Agent permission request routes to the delegate")
    func permissionDelegate() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.start()

        let delegate = TestDelegate()
        let client = ACPClient(transport: transport, delegate: delegate)
        await client.start()

        let params = try ACPJSON.value(from: RequestPermissionRequest(
            sessionId: "s",
            toolCall: ToolCallUpdate(toolCallId: "t1"),
            options: [PermissionOption(optionId: "ok", name: "Allow", kind: .allowOnce)]
        ))
        let response = await simulator.requestClient(method: ACPMethod.sessionRequestPermission, id: 1, params: params)
        let outcome = try ACPJSON.decode(RequestPermissionResponse.self, from: response.result ?? .null)
        #expect(outcome.outcome == .selected(optionId: "ok"))
    }

    @Test("Agent file reads and writes route to the delegate")
    func fileSystemDelegate() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.start()

        let delegate = TestDelegate()
        let client = ACPClient(transport: transport, delegate: delegate)
        await client.start()

        let readParams = try ACPJSON.value(from: ReadTextFileRequest(sessionId: "s", path: "/a"))
        let readResp = await simulator.requestClient(method: ACPMethod.fsReadTextFile, id: 2, params: readParams)
        let read = try ACPJSON.decode(ReadTextFileResponse.self, from: readResp.result ?? .null)
        #expect(read.content == "file body")

        let writeParams = try ACPJSON.value(from: WriteTextFileRequest(sessionId: "s", path: "/b", content: "x"))
        let writeResp = await simulator.requestClient(method: ACPMethod.fsWriteTextFile, id: 3, params: writeParams)
        #expect(writeResp.error == nil)
        #expect(delegate.lock.withLock { delegate.writtenPaths } == ["/b"])
    }

    @Test("Terminal requests route to the delegate")
    func terminalDelegate() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.start()

        let delegate = TestDelegate()
        let client = ACPClient(transport: transport, delegate: delegate)
        await client.start()

        let createParams = try ACPJSON.value(from: CreateTerminalRequest(sessionId: "s", command: "ls"))
        let createResp = await simulator.requestClient(method: ACPMethod.terminalCreate, id: 4, params: createParams)
        let created = try ACPJSON.decode(CreateTerminalResponse.self, from: createResp.result ?? .null)
        #expect(created.terminalId == "term-1")

        let termParams = try ACPJSON.value(from: TerminalRequest(sessionId: "s", terminalId: "term-1"))
        let outputResp = await simulator.requestClient(method: ACPMethod.terminalOutput, id: 5, params: termParams)
        let output = try ACPJSON.decode(TerminalOutputResponse.self, from: outputResp.result ?? .null)
        #expect(output.output == "hello")

        let waitResp = await simulator.requestClient(method: ACPMethod.terminalWaitForExit, id: 6, params: termParams)
        let wait = try ACPJSON.decode(WaitForExitResponse.self, from: waitResp.result ?? .null)
        #expect(wait.exitCode == 0)

        let releaseResp = await simulator.requestClient(method: ACPMethod.terminalRelease, id: 7, params: termParams)
        #expect(releaseResp.error == nil)
        let killResp = await simulator.requestClient(method: ACPMethod.terminalKill, id: 8, params: termParams)
        #expect(killResp.error == nil)
        #expect(delegate.lock.withLock { delegate.writtenPaths }.contains("released:term-1"))
        #expect(delegate.lock.withLock { delegate.writtenPaths }.contains("killed:term-1"))
    }

    @Test("A non-JSON-RPC error from the delegate becomes an internal error")
    func genericDelegateError() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.start()

        let delegate = ThrowingDelegate()
        let client = ACPClient(transport: transport, delegate: delegate)
        await client.start()

        let params = try ACPJSON.value(from: ReadTextFileRequest(sessionId: "s", path: "/a"))
        let resp = await simulator.requestClient(method: ACPMethod.fsReadTextFile, id: 9, params: params)
        #expect(resp.error?.code == -32603)
    }

    @Test("Default delegate methods report unsupported operations")
    func defaultDelegateMethods() async throws {
        let delegate = DefaultDelegate()
        let permission = await delegate.requestPermission(RequestPermissionRequest(
            sessionId: "s", toolCall: ToolCallUpdate(toolCallId: "t"), options: []))
        #expect(permission.outcome == .cancelled)

        await #expect(throws: JSONRPCError.self) { _ = try await delegate.readTextFile(ReadTextFileRequest(sessionId: "s", path: "/a")) }
        await #expect(throws: JSONRPCError.self) { try await delegate.writeTextFile(WriteTextFileRequest(sessionId: "s", path: "/a", content: "x")) }
        await #expect(throws: JSONRPCError.self) { _ = try await delegate.createTerminal(CreateTerminalRequest(sessionId: "s", command: "ls")) }
        let term = TerminalRequest(sessionId: "s", terminalId: "t")
        await #expect(throws: JSONRPCError.self) { _ = try await delegate.terminalOutput(term) }
        await #expect(throws: JSONRPCError.self) { try await delegate.releaseTerminal(term) }
        await #expect(throws: JSONRPCError.self) { _ = try await delegate.waitForTerminalExit(term) }
        await #expect(throws: JSONRPCError.self) { try await delegate.killTerminal(term) }
    }

    @Test("Unknown method without delegate support reports method not found")
    func defaultDelegateUnsupported() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.start()

        let delegate = DefaultDelegate()
        let client = ACPClient(transport: transport, delegate: delegate)
        await client.start()

        let readParams = try ACPJSON.value(from: ReadTextFileRequest(sessionId: "s", path: "/a"))
        let resp = await simulator.requestClient(method: ACPMethod.fsReadTextFile, id: 7, params: readParams)
        #expect(resp.error?.code == -32601)
    }

    @Test("Requests without a delegate are rejected")
    func noDelegate() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.start()

        let client = ACPClient(transport: transport)
        await client.start()
        let resp = await simulator.requestClient(method: ACPMethod.fsReadTextFile, id: 8, params: .object([:]))
        #expect(resp.error?.code == -32601)
    }

    @Test("close finishes update streams")
    func closeFinishesStreams() async throws {
        let transport = MockTransport()
        let simulator = AgentSimulator(transport)
        await simulator.respond(to: ACPMethod.sessionNew, encodable: NewSessionResponse(sessionId: "s"))
        await simulator.start()

        let client = ACPClient(transport: transport)
        await client.start()
        _ = try await client.newSession(NewSessionRequest(cwd: "/tmp"))
        let stream = await client.updates(for: "s")
        await client.close()

        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0) // stream finished without elements
    }
}
