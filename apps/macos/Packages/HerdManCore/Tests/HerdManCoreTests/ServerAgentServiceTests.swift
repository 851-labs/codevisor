import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@Suite("ServerHarnessService")
struct ServerAgentServiceTests {
    @Test("listSessions prefers the harness's native on-disk sessions")
    func nativeSessions() async throws {
        let native = [SessionInfo(sessionId: "native-1", cwd: "/repo", title: "Old chat")]
        let client = AgentSessionsFakeClient(agentSessions: .success(native))
        let service = ServerHarnessService(client: client)

        let sessions = try await service.listSessions(forHarnessId: "claude-code")

        #expect(sessions == native)
        #expect(client.requestedHarnessIds == ["claude-code"])
        // The legacy DB path is untouched when the endpoint exists.
        #expect(client.listSessionsCalls == 0)
    }

    @Test("listSessions falls back to HerdMan's DB sessions on 404 (older servers)")
    func legacyFallback() async throws {
        let client = AgentSessionsFakeClient(
            agentSessions: .failure(HerdManServerClientError.httpStatus(404, "no route")),
            dbSessions: [
                ServerSession(
                    id: "s1", projectId: "p1", serverId: "local", harnessId: "claude-code",
                    agentSessionId: "agent-1", title: "DB chat", origin: .imported,
                    isArchived: false, worktreeName: nil, cwd: "/db/repo",
                    createdAt: "2026-01-01T00:00:00.000Z",
                    updatedAt: "2026-01-02T00:00:00.000Z", usage: nil
                ),
                ServerSession(
                    id: "s2", projectId: "p1", serverId: "local", harnessId: "codex",
                    agentSessionId: nil, title: "Other harness", origin: .herdman,
                    isArchived: false, worktreeName: nil, cwd: "/db/repo",
                    createdAt: "2026-01-01T00:00:00.000Z", updatedAt: nil, usage: nil
                )
            ]
        )
        let service = ServerHarnessService(client: client)

        let sessions = try await service.listSessions(forHarnessId: "claude-code")

        #expect(sessions == [
            SessionInfo(
                sessionId: "agent-1", cwd: "/db/repo", title: "DB chat",
                updatedAt: "2026-01-02T00:00:00.000Z"
            )
        ])
    }

    @Test("listSessions propagates non-404 errors")
    func errorPropagation() async {
        let client = AgentSessionsFakeClient(
            agentSessions: .failure(HerdManServerClientError.httpStatus(500, "boom"))
        )
        let service = ServerHarnessService(client: client)

        await #expect(throws: HerdManServerClientError.httpStatus(500, "boom")) {
            _ = try await service.listSessions(forHarnessId: "claude-code")
        }
    }
}

private final class AgentSessionsFakeClient: HerdManServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private let agentSessions: Result<[SessionInfo], Error>
    private let dbSessions: [ServerSession]
    private(set) var requestedHarnessIds: [String] = []
    private(set) var listSessionsCalls = 0

    init(agentSessions: Result<[SessionInfo], Error>, dbSessions: [ServerSession] = []) {
        self.agentSessions = agentSessions
        self.dbSessions = dbSessions
    }

    func listAgentSessions(harnessId: String) async throws -> [SessionInfo] {
        lock.withLock { requestedHarnessIds.append(harnessId) }
        return try agentSessions.get()
    }

    func listSessions() async throws -> [ServerSession] {
        lock.withLock { listSessionsCalls += 1 }
        return dbSessions
    }

    func listProjects() async throws -> [ServerProject] { [] }
    func listHarnesses() async throws -> [ServerHarness] { [] }
    func health() async throws -> ServerHealth { ServerHealth(ok: true, version: "0", database: "ready") }
    func info() async throws -> ServerInfo { fatalError("unused") }
    func updateInfo() async throws -> ServerUpdateInfo { fatalError("unused") }
    func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
    func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func deleteProject(id: UUID) async throws {}
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
    func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func deleteSession(id: UUID) async throws {}
    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }
    func cancelSession(id: UUID) async throws {}
    func setSessionMode(id: UUID, modeId: String) async throws {}
    func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
    func requestShutdown() async throws {}
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}
