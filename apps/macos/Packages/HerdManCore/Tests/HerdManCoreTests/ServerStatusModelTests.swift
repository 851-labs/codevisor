import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@MainActor
@Suite("ServerStatusModel")
struct ServerStatusModelTests {
    @Test("Refresh loads health, info, and update state")
    func refreshLoadsStatus() async {
        let client = FakeStatusServerClient()
        let model = ServerStatusModel(client: client)

        await model.refresh()

        #expect(model.health?.ok == true)
        #expect(model.info?.id == "local")
        #expect(model.update?.latestVersion == "0.2.0")
        #expect(model.update?.updateAvailable == true)
        #expect(model.errorMessage == nil)
        #expect(model.isRefreshing == false)
    }

    @Test("Refresh records errors and clears refreshing")
    func refreshRecordsErrors() async {
        let client = FakeStatusServerClient(healthError: StatusTestError())
        let model = ServerStatusModel(client: client)

        await model.refresh()

        #expect(model.errorMessage?.contains("StatusTestError") == true)
        #expect(model.isRefreshing == false)
    }

    @Test("Pairing token forwards to the server")
    func pairingToken() async throws {
        let client = FakeStatusServerClient()
        let model = ServerStatusModel(client: client)

        let token = try await model.issuePairingToken()

        #expect(token.token == "hm_test")
        #expect(client.pairingTokenRequests == 1)
    }
}

private struct StatusTestError: Error {}

private final class FakeStatusServerClient: HerdManServerClienting, @unchecked Sendable {
    private let healthError: (any Error)?
    private let lock = NSLock()
    private var _pairingTokenRequests = 0

    init(healthError: (any Error)? = nil) {
        self.healthError = healthError
    }

    var pairingTokenRequests: Int {
        lock.withLock { _pairingTokenRequests }
    }

    func health() async throws -> ServerHealth {
        if let healthError {
            throw healthError
        }
        return ServerHealth(ok: true, version: "0.1.0", database: "ready")
    }

    func info() async throws -> ServerInfo {
        ServerInfo(
            id: "local",
            name: "Local HerdMan",
            kind: "local",
            version: "0.1.0",
            platform: "darwin",
            bindHost: "127.0.0.1"
        )
    }

    func updateInfo() async throws -> ServerUpdateInfo {
        ServerUpdateInfo(
            currentVersion: "0.1.0",
            latestVersion: "0.2.0",
            updateAvailable: true,
            channel: "development",
            checkedAt: "2026-06-30T00:00:00.000Z",
            migrationState: "idle"
        )
    }

    func issuePairingToken() async throws -> ServerPairingToken {
        lock.withLock { _pairingTokenRequests += 1 }
        return ServerPairingToken(token: "hm_test", createdAt: "2026-06-30T00:00:00.000Z")
    }

    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
    func listHarnesses() async throws -> [ServerHarness] { [] }
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
    func listWorkspaces() async throws -> [ServerWorkspace] { [] }
    func upsertWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace { fatalError("unused") }
    func updateWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace { fatalError("unused") }
    func deleteWorkspace(id: UUID) async throws {}
    func listSessions() async throws -> [ServerSession] { [] }
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
    func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func deleteSession(id: UUID) async throws {}
    func promptSession(id: UUID, text: String) async throws -> StopReason { .endTurn }
    func cancelSession(id: UUID) async throws {}
    func setSessionMode(id: UUID, modeId: String) async throws {}
    func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}
