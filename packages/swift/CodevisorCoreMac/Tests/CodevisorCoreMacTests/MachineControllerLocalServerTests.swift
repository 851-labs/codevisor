import Foundation
import Testing
@testable import CodevisorCore
@testable import CodevisorCoreMac

/// MachineController behavior that depends on the concrete macOS
/// `LocalCodevisorServer` (process launching). The controller itself is
/// shared and platform-neutral; these integration tests live here because
/// they construct the real local server.
@MainActor
@Suite("MachineController + LocalCodevisorServer")
struct MachineControllerLocalServerTests {
    @Test("prepareSelectedMachine rescans harnesses on an already-running local server")
    func rescanOnAlreadyRunningServer() async throws {
        let client = RescanCountingClient()
        // A healthy durable server: ensureRunning resolves .alreadyRunning
        // without launching, which must trigger exactly one PATH rescan (the
        // durable server's PATH is frozen at its original launch).
        let localServer = LocalCodevisorServer(
            client: client,
            entrypoint: URL(fileURLWithPath: "/tmp/main.js"),
            launcher: { _ in Process() }
        )
        let (controller, _, _) = makeController(client: client, localServer: localServer)

        await controller.prepareSelectedMachine()
        try await waitForSync { client.rescans == 1 }
        controller.stopEventSync()

        #expect(localServer.state == .alreadyRunning)
        #expect(client.rescans == 1)
    }

    @Test("prepareSelectedMachine skips the rescan when it launches the server fresh")
    func noRescanOnFreshLaunch() async throws {
        // First health probe fails (no durable server); the post-launch poll
        // succeeds. A fresh launch already resolved PATH — no rescan needed.
        let client = RescanCountingClient(failFirstHealth: true)
        let localServer = LocalCodevisorServer(
            client: client,
            entrypoint: URL(fileURLWithPath: "/tmp/main.js"),
            launcher: { request in
                client.acceptBoot(request.bootId)
                return Process()
            }
        )
        let (controller, _, _) = makeController(client: client, localServer: localServer)

        await controller.prepareSelectedMachine()
        try await Task.sleep(nanoseconds: 30_000_000)
        controller.stopEventSync()

        #expect(localServer.state == .started)
        #expect(client.rescans == 0)
    }

    @Test("Concurrent machine preparation shares one readiness flow")
    func concurrentPreparationIsCoalesced() async throws {
        let client = RescanCountingClient()
        let localServer = LocalCodevisorServer(
            client: client,
            entrypoint: URL(fileURLWithPath: "/tmp/main.js"),
            launcher: { _ in Process() }
        )
        let (controller, _, _) = makeController(client: client, localServer: localServer)

        let first = Task { await controller.prepareSelectedMachine() }
        let second = Task { await controller.prepareSelectedMachine() }
        await first.value
        await second.value
        try await waitForSync { client.rescans == 1 }
        controller.stopEventSync()

        #expect(client.rescans == 1)
    }

    private func makeController(
        client: any CodevisorServerClienting,
        localServer: LocalCodevisorServer
    ) -> (
        controller: MachineController,
        projectList: ProjectListModel,
        store: InMemoryStore
    ) {
        let store = InMemoryStore()
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let controller = MachineController(
            store: store,
            projectList: projectList,
            localServer: localServer,
            clientFactory: { _ in client }
        )
        return (controller, projectList, store)
    }

    private func waitForSync(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for sync condition")
    }
}

/// Counts rescan calls; healthy by default so `ensureRunning` sees a durable
/// server, or unhealthy on the first probe to force a fresh launch.
/// (Local copy of the fake in CodevisorCoreTests' MachineControllerTests —
/// it is private to that file.)
private final class RescanCountingClient: CodevisorServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _rescans = 0
    private var _failNextHealth: Bool
    private var _bootId: String?

    init(failFirstHealth: Bool = false) {
        _failNextHealth = failFirstHealth
    }

    var rescans: Int { lock.withLock { _rescans } }

    struct HealthError: Error {}

    func acceptBoot(_ bootId: String) {
        lock.withLock { _bootId = bootId }
    }

    func health() async throws -> ServerHealth {
        let (failNow, bootId) = lock.withLock {
            let fail = _failNextHealth
            _failNextHealth = false
            return (fail, _bootId)
        }
        if failNow { throw HealthError() }
        return ServerHealth(
            ok: true,
            version: "0.1.0",
            database: "ready",
            bootId: bootId
        )
    }

    func info() async throws -> ServerInfo {
        ServerInfo(
            id: "local", name: "Local", kind: "local", version: "0.1.0",
            platform: "darwin", bindHost: "127.0.0.1"
        )
    }

    func rescanHarnesses() async throws -> [ServerHarness] {
        lock.withLock { _rescans += 1 }
        return []
    }

    func listHarnesses() async throws -> [ServerHarness] { [] }
    func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
        ServerUpdateInfo(
            currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
            channel: "stable", checkedAt: nil, migrationState: "idle"
        )
    }
    func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
    func listProjects() async throws -> [ServerProject] { [] }
    func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func deleteProject(id: UUID) async throws {}
    func listSessions() async throws -> [ServerSession] { [] }
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
