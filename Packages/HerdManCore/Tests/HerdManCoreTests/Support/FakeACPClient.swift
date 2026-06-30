import Foundation
import ACPKit
@testable import HerdManCore

/// A scripted `ACPClientProtocol` for testing `SessionModel`. During `prompt`
/// it emits a preconfigured sequence of updates into the session stream, then
/// returns a stop reason (or throws).
final class FakeACPClient: ACPClientProtocol, @unchecked Sendable {
    private let stream: AsyncStream<SessionUpdate>
    private let continuation: AsyncStream<SessionUpdate>.Continuation

    var scriptedUpdates: [SessionUpdate] = []
    var stopReason: StopReason = .endTurn
    var promptError: (any Error)?

    private(set) var cancelledSessions: [String] = []
    private(set) var setModes: [String] = []
    private(set) var setConfigOptions: [(configId: String, value: String)] = []
    var configOptionsResult: [SessionConfigOption] = []
    var setConfigError: (any Error)?

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: SessionUpdate.self)
    }

    func initialize(_ request: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(protocolVersion: 1)
    }

    func authenticate(_ request: AuthenticateRequest) async throws {}

    var newSessionId = "session"
    var listSessionsResult: [SessionInfo] = []
    private(set) var loadedSessions: [String] = []
    private(set) var deletedSessions: [String] = []

    func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: newSessionId)
    }

    func loadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        loadedSessions.append(request.sessionId)
        for update in scriptedUpdates {
            continuation.yield(update)
        }
        return LoadSessionResponse()
    }

    func listSessions(_ request: ListSessionsRequest) async throws -> ListSessionsResponse {
        ListSessionsResponse(sessions: listSessionsResult)
    }

    func deleteSession(_ request: DeleteSessionRequest) async throws {
        deletedSessions.append(request.sessionId)
    }

    func prompt(_ request: PromptRequest) async throws -> PromptResponse {
        if let promptError { throw promptError }
        for update in scriptedUpdates {
            continuation.yield(update)
        }
        return PromptResponse(stopReason: stopReason)
    }

    func setMode(_ request: SetSessionModeRequest) async throws {
        setModes.append(request.modeId)
    }

    func setConfigOption(_ request: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse {
        if let setConfigError { throw setConfigError }
        setConfigOptions.append((request.configId, request.value))
        return SetSessionConfigOptionResponse(configOptions: configOptionsResult)
    }

    func cancel(sessionId: String) async throws {
        cancelledSessions.append(sessionId)
    }

    func updates(for sessionId: String) async -> AsyncStream<SessionUpdate> {
        stream
    }

    func close() async {
        continuation.finish()
    }
}

struct CustomError: Error {}
