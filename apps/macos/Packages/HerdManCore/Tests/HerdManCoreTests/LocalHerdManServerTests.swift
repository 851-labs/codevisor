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
            serverEnvironmentProvider: {
                ["PATH": "/opt/homebrew/bin:/usr/bin", "HERDMAN_TEST": "1"]
            },
            launcher: { request in
                launches.append(request)
                return Process()
            }
        )

        let state = await server.ensureRunning()

        #expect(state == .started)
        #expect(launches.first?.entrypoint == entrypoint)
        #expect(launches.first?.databasePath == "/tmp/herdman.sqlite")
        #expect(launches.first?.host == "0.0.0.0")
        #expect(launches.first?.name.isEmpty == false)
        #expect(launches.first?.port == HerdManServerConfig.localPort)
        #expect(launches.first?.environment["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(launches.first?.environment["HERDMAN_TEST"] == "1")
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

    @Test("Resolves the bundled runtime directory by path, not Bundle resource lookup")
    func bundledRuntimeDirectoryByPath() throws {
        let resources = try makeTemporaryDirectory()
        #if arch(x86_64)
            let target = "darwin-x64"
        #else
            let target = "darwin-arm64"
        #endif
        let runtime = resources.appendingPathComponent("server/\(target)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: runtime.appendingPathComponent("main.js").path, contents: Data())
        FileManager.default.createFile(
            atPath: runtime.appendingPathComponent("bin/node").path,
            contents: Data(),
            attributes: [.posixPermissions: 0o755]
        )

        let resolved = LocalHerdManServer.bundledServerRuntimeDirectory(resourcesURL: resources)

        #expect(resolved?.standardizedFileURL.path == runtime.standardizedFileURL.path)
    }

    @Test("Replaces a durable server that is older than the bundled runtime")
    func replacesStaleServer() async throws {
        let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
        let client = FakeLocalServerClient(healthResults: [
            .success(.running(version: "0.1.9")), // initial probe: stale server alive
            .failure(TestError()),                // shutdown poll: it exited
            .failure(TestError()),                // stopStaleServer survival check: gone
            .failure(TestError()),                // ensureRunning re-check before launching
            .success(.running(version: "0.2.0"))  // launched runtime becomes healthy
        ])
        var launches: [LocalHerdManServerLaunchRequest] = []
        var terminatedPorts: [Int] = []
        let server = LocalHerdManServer(
            client: client,
            entrypoint: entrypoint,
            launcher: { request in
                launches.append(request)
                return Process()
            },
            staleListenerTerminator: { terminatedPorts.append($0) }
        )

        let state = await server.ensureRunning()

        #expect(state == .started)
        #expect(launches.count == 1)
        #expect(client.shutdownRequests == 1)
        #expect(terminatedPorts.isEmpty)
    }

    @Test("Signals a stale server that ignores the shutdown request")
    func signalsStaleServerWithoutShutdownEndpoint() async throws {
        let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
        let client = FakeLocalServerClient(healthResults: [
            .success(.running(version: "0.1.9")), // initial probe: stale server alive
            .success(.running(version: "0.1.9")), // shutdown poll: still up
            .failure(TestError()),                // shutdown poll: gives up cleanly
            .success(.running(version: "0.1.9")), // survival check: it ignored shutdown
            .failure(TestError()),                // post-signal poll: now gone
            .failure(TestError()),                // ensureRunning re-check before launching
            .success(.running(version: "0.2.0"))  // launched runtime becomes healthy
        ])
        var launches: [LocalHerdManServerLaunchRequest] = []
        var terminatedPorts: [Int] = []
        let server = LocalHerdManServer(
            client: client,
            entrypoint: entrypoint,
            launcher: { request in
                launches.append(request)
                return Process()
            },
            staleListenerTerminator: { terminatedPorts.append($0) }
        )

        let state = await server.ensureRunning()

        #expect(state == .started)
        #expect(launches.count == 1)
        #expect(terminatedPorts == [HerdManServerConfig.localPort])
    }

    @Test("Keeps a durable server that matches the bundled runtime version")
    func keepsUpToDateServer() async throws {
        let entrypoint = try makeRuntimeEntrypoint(version: "0.2.0")
        let client = FakeLocalServerClient(healthResults: [.success(.running(version: "0.2.0"))])
        var launches: [LocalHerdManServerLaunchRequest] = []
        var terminatedPorts: [Int] = []
        let server = LocalHerdManServer(
            client: client,
            entrypoint: entrypoint,
            launcher: { request in
                launches.append(request)
                return Process()
            },
            staleListenerTerminator: { terminatedPorts.append($0) }
        )

        let state = await server.ensureRunning()

        #expect(state == .alreadyRunning)
        #expect(launches.isEmpty)
        #expect(client.shutdownRequests == 0)
        #expect(terminatedPorts.isEmpty)
    }

    @Test("Keeps a healthy server when the runtime has no VERSION file (dev builds)")
    func keepsServerWithoutBundledVersion() async throws {
        let entrypoint = try makeTemporaryDirectory().appendingPathComponent("main.js")
        let client = FakeLocalServerClient(healthResults: [.success(.running(version: "0.0.1"))])
        var launches: [LocalHerdManServerLaunchRequest] = []
        let server = LocalHerdManServer(
            client: client,
            entrypoint: entrypoint,
            launcher: { request in
                launches.append(request)
                return Process()
            },
            staleListenerTerminator: { _ in }
        )

        let state = await server.ensureRunning()

        #expect(state == .alreadyRunning)
        #expect(launches.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdman-server-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A runtime directory shaped like a release bundle's: main.js beside a
    /// VERSION file. Returns the entrypoint URL.
    private func makeRuntimeEntrypoint(version: String) throws -> URL {
        let directory = try makeTemporaryDirectory()
        try version.write(
            to: directory.appendingPathComponent("VERSION"),
            atomically: true,
            encoding: .utf8
        )
        return directory.appendingPathComponent("main.js")
    }
}

private struct TestError: Error {}

private extension ServerHealth {
    static let ready = ServerHealth(ok: true, version: "0.1.0", database: "ready")

    static func running(version: String) -> ServerHealth {
        ServerHealth(ok: true, version: version, database: "ready")
    }
}

private final class FakeLocalServerClient: HerdManServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var healthResults: [Result<ServerHealth, Error>]
    private(set) var shutdownRequests = 0

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

    func requestShutdown() async throws {
        lock.withLock { shutdownRequests += 1 }
    }

    func listHarnesses() async throws -> [ServerHarness] { [] }
    func info() async throws -> ServerInfo { fatalError("unused") }
    func updateInfo() async throws -> ServerUpdateInfo { fatalError("unused") }
    func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
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
    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }
    func cancelSession(id: UUID) async throws {}
    func setSessionMode(id: UUID, modeId: String) async throws {}
    func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}
