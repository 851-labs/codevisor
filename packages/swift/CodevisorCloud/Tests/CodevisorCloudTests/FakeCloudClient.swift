import CodevisorClient
import CodevisorProtocol
import Foundation
@testable import CodevisorCloud

// Shared fakes and factories for CloudAccountController suites (extracted so
// the test files stay under the structural lint limits).

/// A scriptable stand-in for the cloud REST client.
final class FakeCloudClient: CloudAccountClienting, @unchecked Sendable {
    private let lock = NSLock()

    var discoverResult: Result<CloudInstanceInfo, any Error> = .success(
        CloudInstanceInfo(service: "codevisor-cloud", instance: "Test Cloud")
    )
    var verifyResult: Result<String, any Error> = .failure(CloudAccountClientError.missingToken)
    var devLoginResult: Result<String, any Error> = .failure(CloudAccountClientError.missingToken)
    /// Tokens the fake accepts, mapped to the user get-session reports.
    var sessions: [String: CloudSessionUser] = [:]
    var machinesResult: Result<[CloudMachine], any Error> = .success([])
    var renameError: (any Error)?
    var removeError: (any Error)?

    private(set) var sessionTokens: [String] = []
    private(set) var machineTokens: [String] = []
    private(set) var renames: [(deviceId: String, name: String)] = []
    private(set) var removals: [String] = []

    func discover() async throws -> CloudInstanceInfo {
        try lock.withLock { discoverResult }.get()
    }

    func verifyOneTimeToken(_ ott: String) async throws -> String {
        try lock.withLock { verifyResult }.get()
    }

    func developmentLogin() async throws -> String {
        try lock.withLock { devLoginResult }.get()
    }

    func session(token: String) async throws -> CloudSessionUser? {
        lock.withLock {
            sessionTokens.append(token)
            return sessions[token]
        }
    }

    func machines(token: String) async throws -> [CloudMachine] {
        try lock.withLock {
            machineTokens.append(token)
            return machinesResult
        }.get()
    }

    func rename(deviceId: String, name: String, token: String) async throws {
        let error: (any Error)? = lock.withLock {
            renames.append((deviceId: deviceId, name: name))
            return renameError
        }
        if let error { throw error }
    }

    func removeMachine(deviceId: String, token: String) async throws {
        let error: (any Error)? = lock.withLock {
            removals.append(deviceId)
            return removeError
        }
        if let error { throw error }
    }
}

/// The embedded local server, reduced to its /v1/cloud registration surface.
/// Everything else is the minimal boilerplate the protocol requires.
final class FakeLocalServerClient: CodevisorServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _registration: ServerCloudRegistration
    private var _connects: [(serverURL: URL, sessionToken: String)] = []
    private var _disconnects = 0
    var connectError: (any Error)?

    init(registration: ServerCloudRegistration = ServerCloudRegistration(connected: false)) {
        _registration = registration
    }

    var connects: [(serverURL: URL, sessionToken: String)] { lock.withLock { _connects } }
    var disconnects: Int { lock.withLock { _disconnects } }

    func cloudRegistration() async throws -> ServerCloudRegistration {
        lock.withLock { _registration }
    }

    func connectCloud(serverURL: URL, sessionToken: String) async throws -> String {
        if let connectError { throw connectError }
        return lock.withLock {
            _connects.append((serverURL: serverURL, sessionToken: sessionToken))
            _registration = ServerCloudRegistration(
                connected: true,
                deviceId: "local-device-1",
                state: "connected",
                managedBy: "app"
            )
            return "local-device-1"
        }
    }

    func disconnectCloud() async throws {
        lock.withLock {
            _disconnects += 1
            _registration = ServerCloudRegistration(connected: false)
        }
    }

    // MARK: - Unused protocol surface

    func health() async throws -> ServerHealth {
        ServerHealth(ok: true, version: "0.1.0", database: "ready", bootId: nil)
    }

    func info() async throws -> ServerInfo {
        ServerInfo(
            id: "local", name: "Local", kind: "local", version: "0.1.0",
            platform: "darwin", bindHost: "127.0.0.1"
        )
    }

    func rescanHarnesses() async throws -> [ServerHarness] { [] }
    func listHarnesses() async throws -> [ServerHarness] { [] }
    func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
        ServerUpdateInfo(
            currentVersion: "0.1.0", latestVersion: "0.1.0", updateAvailable: false,
            channel: "stable", checkedAt: nil, migrationState: "idle"
        )
    }

    func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
    func capabilities(cwd: String) async throws -> ServerCapabilities {
        ServerCapabilities(harnesses: [])
    }

    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness {
        fatalError("unused")
    }

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
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

/// Every call fails like an unreachable host.
struct OfflineError: Error {}

struct OfflineCloudClient: CloudAccountClienting {
    func discover() async throws -> CloudInstanceInfo { throw OfflineError() }
    func verifyOneTimeToken(_ ott: String) async throws -> String { throw OfflineError() }
    func developmentLogin() async throws -> String { throw OfflineError() }
    func session(token: String) async throws -> CloudSessionUser? { throw OfflineError() }
    func machines(token: String) async throws -> [CloudMachine] { throw OfflineError() }
    func rename(deviceId: String, name: String, token: String) async throws { throw OfflineError() }
    func removeMachine(deviceId: String, token: String) async throws { throw OfflineError() }
}

/// A canned cloud machine presence entry (key defaults to `pk_<deviceId>`).
func testMachine(
    _ deviceId: String,
    name: String = "Mac Studio",
    online: Bool = true,
    publicKey: String? = nil
) -> CloudMachine {
    CloudMachine(
        deviceId: deviceId,
        name: name,
        os: "macos",
        appVersion: "1.0.0",
        publicKey: publicKey ?? "pk_\(deviceId)",
        online: online,
        lastSeenAt: "2026-08-07T00:00:00.000Z"
    )
}

@MainActor
func makeController(
    client: FakeCloudClient = FakeCloudClient(),
    store: InMemoryCloudCredentialStore = InMemoryCloudCredentialStore(),
    environmentCloud: CodevisorAppVariant.DevelopmentCloud? = nil
) -> (controller: CloudAccountController, client: FakeCloudClient, store: InMemoryCloudCredentialStore) {
    let controller = CloudAccountController(
        clientFactory: { _ in client },
        credentialStore: store,
        environmentCloud: environmentCloud,
        // Inert direct-path probing: account tests must never open real
        // sockets when a refresh sees online machines.
        directPaths: CloudDirectPathController(
            credentialStore: store,
            prober: { _, _, _ in nil }
        )
    )
    return (controller, client, store)
}

/// A controller signed in via the OTT flow with a canned machine list.
@MainActor
func makeSignedIn(
    machines: [CloudMachine]
) async -> (controller: CloudAccountController, client: FakeCloudClient, store: InMemoryCloudCredentialStore) {
    let client = FakeCloudClient()
    client.verifyResult = .success("t")
    client.sessions["t"] = CloudSessionUser(userId: "u1", email: nil)
    client.machinesResult = .success(machines)
    let made = makeController(client: client)
    await made.controller.completeSignIn(ott: "ott")
    return made
}
