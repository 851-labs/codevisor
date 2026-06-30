import Foundation

/// The high-level ACP client interface the application depends on.
public protocol ACPClientProtocol: Sendable {
    func initialize(_ request: InitializeRequest) async throws -> InitializeResponse
    func authenticate(_ request: AuthenticateRequest) async throws
    func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse
    func loadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse
    func listSessions(_ request: ListSessionsRequest) async throws -> ListSessionsResponse
    func deleteSession(_ request: DeleteSessionRequest) async throws
    func prompt(_ request: PromptRequest) async throws -> PromptResponse
    func setMode(_ request: SetSessionModeRequest) async throws
    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse
    func cancel(sessionId: String) async throws
    func updates(for sessionId: String) async -> AsyncStream<SessionUpdate>
    func close() async
}

/// A concrete ACP client driving a single agent connection.
public actor ACPClient: ACPClientProtocol, ACPConnectionHandler {
    private let connection: ACPConnection
    private weak var delegate: (any ACPClientDelegate)?

    private struct Channel {
        let stream: AsyncStream<SessionUpdate>
        let continuation: AsyncStream<SessionUpdate>.Continuation
    }
    private var channels: [String: Channel] = [:]

    public init(transport: any Transport, delegate: (any ACPClientDelegate)? = nil) {
        self.connection = ACPConnection(transport: transport)
        self.delegate = delegate
    }

    /// Begins reading from the underlying transport. Must be called before use.
    public func start() async {
        await connection.start(handler: self)
    }

    // MARK: - Agent requests

    public func initialize(_ request: InitializeRequest) async throws -> InitializeResponse {
        try await send(ACPMethod.initialize, request, as: InitializeResponse.self)
    }

    public func authenticate(_ request: AuthenticateRequest) async throws {
        try await sendVoid(ACPMethod.authenticate, request)
    }

    public func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        let response = try await send(ACPMethod.sessionNew, request, as: NewSessionResponse.self)
        _ = ensureChannel(response.sessionId)
        return response
    }

    public func loadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        // Ensure the update channel exists before history replays.
        _ = ensureChannel(request.sessionId)
        return try await send(ACPMethod.sessionLoad, request, as: LoadSessionResponse.self)
    }

    public func listSessions(_ request: ListSessionsRequest) async throws -> ListSessionsResponse {
        try await send(ACPMethod.sessionList, request, as: ListSessionsResponse.self)
    }

    public func deleteSession(_ request: DeleteSessionRequest) async throws {
        try await sendVoid(ACPMethod.sessionDelete, request)
    }

    public func prompt(_ request: PromptRequest) async throws -> PromptResponse {
        try await send(ACPMethod.sessionPrompt, request, as: PromptResponse.self)
    }

    public func setMode(_ request: SetSessionModeRequest) async throws {
        try await sendVoid(ACPMethod.sessionSetMode, request)
    }

    public func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse {
        try await send(ACPMethod.sessionSetConfigOption, request, as: SetSessionConfigOptionResponse.self)
    }

    public func cancel(sessionId: String) async throws {
        let params = try ACPJSON.value(from: CancelNotification(sessionId: sessionId))
        try await connection.notify(ACPMethod.sessionCancel, params: params)
    }

    public func updates(for sessionId: String) async -> AsyncStream<SessionUpdate> {
        ensureChannel(sessionId).stream
    }

    public func close() async {
        for channel in channels.values {
            channel.continuation.finish()
        }
        channels.removeAll()
        await connection.close()
    }

    // MARK: - ACPConnectionHandler

    public func handleNotification(method: String, params: JSONValue?) async {
        guard method == ACPMethod.sessionUpdate, let params else { return }
        guard let notification = try? ACPJSON.decode(SessionNotification.self, from: params) else { return }
        ensureChannel(notification.sessionId).continuation.yield(notification.update)
    }

    public func handleRequest(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let delegate else { return .failure(.methodNotFound(method)) }
        let params = params ?? .object([:])
        do {
            switch method {
            case ACPMethod.sessionRequestPermission:
                let request = try ACPJSON.decode(RequestPermissionRequest.self, from: params)
                return .success(try ACPJSON.value(from: await delegate.requestPermission(request)))
            case ACPMethod.fsReadTextFile:
                let request = try ACPJSON.decode(ReadTextFileRequest.self, from: params)
                return .success(try ACPJSON.value(from: try await delegate.readTextFile(request)))
            case ACPMethod.fsWriteTextFile:
                let request = try ACPJSON.decode(WriteTextFileRequest.self, from: params)
                try await delegate.writeTextFile(request)
                return .success(.object([:]))
            case ACPMethod.terminalCreate:
                let request = try ACPJSON.decode(CreateTerminalRequest.self, from: params)
                return .success(try ACPJSON.value(from: try await delegate.createTerminal(request)))
            case ACPMethod.terminalOutput:
                let request = try ACPJSON.decode(TerminalRequest.self, from: params)
                return .success(try ACPJSON.value(from: try await delegate.terminalOutput(request)))
            case ACPMethod.terminalRelease:
                let request = try ACPJSON.decode(TerminalRequest.self, from: params)
                try await delegate.releaseTerminal(request)
                return .success(.object([:]))
            case ACPMethod.terminalWaitForExit:
                let request = try ACPJSON.decode(TerminalRequest.self, from: params)
                return .success(try ACPJSON.value(from: try await delegate.waitForTerminalExit(request)))
            case ACPMethod.terminalKill:
                let request = try ACPJSON.decode(TerminalRequest.self, from: params)
                try await delegate.killTerminal(request)
                return .success(.object([:]))
            default:
                return .failure(.methodNotFound(method))
            }
        } catch let error as JSONRPCError {
            return .failure(error)
        } catch {
            return .failure(.internalError(String(describing: error)))
        }
    }

    // MARK: - Helpers

    private func ensureChannel(_ sessionId: String) -> Channel {
        if let channel = channels[sessionId] { return channel }
        let (stream, continuation) = AsyncStream.makeStream(of: SessionUpdate.self)
        let channel = Channel(stream: stream, continuation: continuation)
        channels[sessionId] = channel
        return channel
    }

    private func send<Req: Encodable, Res: Decodable>(
        _ method: String,
        _ request: Req,
        as type: Res.Type
    ) async throws -> Res {
        let params = try ACPJSON.value(from: request)
        let result = try await connection.request(method, params: params)
        return try ACPJSON.decode(Res.self, from: result)
    }

    private func sendVoid<Req: Encodable>(_ method: String, _ request: Req) async throws {
        let params = try ACPJSON.value(from: request)
        _ = try await connection.request(method, params: params)
    }
}
