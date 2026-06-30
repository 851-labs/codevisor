import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@MainActor
@Suite("LocalHerdManServer")
struct LocalHerdManServerTests {
    @Test("Uses an already healthy local server without launching")
    func alreadyRunning() async {
        let client = FakeLocalServerClient(healthResults: [.success(.ready)])
        var launches: [LocalHerdManServerLaunchRequest] = []
        let server = LocalHerdManServer(
            client: client,
            entrypoint: URL(fileURLWithPath: "/tmp/main.js"),
            launcher: { request in
                launches.append(request)
                return Process()
            }
        )

        let state = await server.ensureRunning()

        #expect(state == .alreadyRunning)
        #expect(launches.isEmpty)
    }

    @Test("Launches the server entrypoint and waits for health")
    func launchesAndWaitsForHealth() async {
        let entrypoint = URL(fileURLWithPath: "/tmp/herdman-server/main.js")
        let client = FakeLocalServerClient(healthResults: [.failure(TestError()), .success(.ready)])
        var launches: [LocalHerdManServerLaunchRequest] = []
        let server = LocalHerdManServer(
            client: client,
            entrypoint: entrypoint,
            nodeExecutable: URL(fileURLWithPath: "/usr/bin/node"),
            databasePath: "/tmp/herdman.sqlite",
            logURL: URL(fileURLWithPath: "/tmp/herdman-server.log"),
            launcher: { request in
                launches.append(request)
                return Process()
            }
        )

        let state = await server.ensureRunning()

        #expect(state == .started)
        #expect(launches.first?.entrypoint == entrypoint)
        #expect(launches.first?.databasePath == "/tmp/herdman.sqlite")
        #expect(launches.first?.host == "127.0.0.1")
        #expect(launches.first?.port == 8765)
    }

    @Test("Reports unavailable when no server entrypoint can be found")
    func missingEntrypoint() async {
        let client = FakeLocalServerClient(healthResults: [.failure(TestError())])
        let server = LocalHerdManServer(client: client, entrypoint: nil)

        let state = await server.ensureRunning()

        guard case let .unavailable(message) = state else {
            Issue.record("expected unavailable")
            return
        }
        #expect(message.contains("entrypoint"))
    }
}

private struct TestError: Error {}

private extension ServerHealth {
    static let ready = ServerHealth(ok: true, version: "0.1.0", database: "ready")
}

private final class FakeLocalServerClient: HerdManServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var healthResults: [Result<ServerHealth, Error>]

    init(healthResults: [Result<ServerHealth, Error>]) {
        self.healthResults = healthResults
    }

    func health() async throws -> ServerHealth {
        let result = lock.withLock {
            healthResults.isEmpty ? .success(.ready) : healthResults.removeFirst()
        }
        switch result {
        case let .success(health):
            return health
        case let .failure(error):
            throw error
        }
    }

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
