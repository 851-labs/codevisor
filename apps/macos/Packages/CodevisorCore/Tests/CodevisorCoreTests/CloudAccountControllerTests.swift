import Foundation
import Testing
@testable import CodevisorCore

/// A scriptable stand-in for the cloud REST client.
private final class FakeCloudClient: CloudAccountClienting, @unchecked Sendable {
    private let lock = NSLock()

    var discoverResult: Result<CloudInstanceInfo, any Error> = .success(
        CloudInstanceInfo(service: "codevisor-cloud", instance: "Test Cloud")
    )
    var verifyResult: Result<String, any Error> = .failure(CloudAccountClientError.missingToken)
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
private final class FakeLocalServerClient: CodevisorServerClienting, @unchecked Sendable {
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
private struct OfflineError: Error {}

private struct OfflineCloudClient: CloudAccountClienting {
    func discover() async throws -> CloudInstanceInfo { throw OfflineError() }
    func verifyOneTimeToken(_ ott: String) async throws -> String { throw OfflineError() }
    func session(token: String) async throws -> CloudSessionUser? { throw OfflineError() }
    func machines(token: String) async throws -> [CloudMachine] { throw OfflineError() }
    func rename(deviceId: String, name: String, token: String) async throws { throw OfflineError() }
    func removeMachine(deviceId: String, token: String) async throws { throw OfflineError() }
}

@MainActor
@Suite("CloudAccountController")
struct CloudAccountControllerTests {
    private static func machine(
        _ deviceId: String,
        name: String = "Mac Studio",
        online: Bool = true
    ) -> CloudMachine {
        CloudMachine(
            deviceId: deviceId,
            name: name,
            os: "macos",
            appVersion: "1.0.0",
            publicKey: "pk_\(deviceId)",
            online: online,
            lastSeenAt: "2026-08-07T00:00:00.000Z"
        )
    }

    private func makeController(
        client: FakeCloudClient = FakeCloudClient(),
        store: InMemoryCloudCredentialStore = InMemoryCloudCredentialStore(),
        environmentCloud: CodevisorAppVariant.DevelopmentCloud? = nil
    ) -> (controller: CloudAccountController, client: FakeCloudClient, store: InMemoryCloudCredentialStore) {
        let controller = CloudAccountController(
            clientFactory: { _ in client },
            credentialStore: store,
            environmentCloud: environmentCloud
        )
        return (controller, client, store)
    }

    @Test("Server URL resolution: custom beats dev cloud beats default")
    func serverURLResolution() throws {
        let dev = CodevisorAppVariant.DevelopmentCloud(
            url: URL(string: "http://127.0.0.1:8787")!,
            token: nil
        )

        let bare = makeController()
        #expect(bare.controller.serverURL == URL(string: "https://cloud.codevisor.dev")!)

        let withDev = makeController(environmentCloud: dev)
        #expect(withDev.controller.serverURL == URL(string: "http://127.0.0.1:8787")!)

        let custom = makeController(
            store: InMemoryCloudCredentialStore(serverURL: URL(string: "https://cloud.example.com")!),
            environmentCloud: dev
        )
        #expect(custom.controller.serverURL == URL(string: "https://cloud.example.com")!)
    }

    @Test("Bootstrap never signs in automatically — the dev account is an explicit action")
    func bootstrapDoesNotAdoptDevToken() async throws {
        let client = FakeCloudClient()
        client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
        let (controller, _, store) = makeController(
            client: client,
            environmentCloud: CodevisorAppVariant.DevelopmentCloud(
                url: URL(string: "http://127.0.0.1:8787")!,
                token: "dev-token"
            )
        )

        await controller.bootstrap()

        #expect(controller.state == .signedOut)
        #expect(try store.token() == nil)
        #expect(controller.developmentAccountAvailable)
    }

    @Test("Signing in with the development account is explicit and stores the token")
    func signInWithDevelopmentAccount() async throws {
        let client = FakeCloudClient()
        client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
        client.machinesResult = .success([Self.machine("dev-1")])
        let (controller, _, store) = makeController(
            client: client,
            environmentCloud: CodevisorAppVariant.DevelopmentCloud(
                url: URL(string: "http://127.0.0.1:8787")!,
                token: "dev-token"
            )
        )

        await controller.signInWithDevelopmentAccount()

        #expect(controller.state == .signedIn(userEmail: "dev@example.com"))
        #expect(try store.token() == "dev-token")
        #expect(controller.machines.map(\.deviceId) == ["dev-1"])

        // Without a dev environment the action (and its button) don't exist.
        let (bare, _, _) = makeController(client: FakeCloudClient())
        #expect(!bare.developmentAccountAvailable)
        await bare.signInWithDevelopmentAccount()
        #expect(bare.state == .signedOut)
    }

    /// Drains chained registration attempts (a successful connect re-refreshes
    /// the machine list, which re-probes and finds the registration in place).
    private func awaitLocalRegistration(_ controller: CloudAccountController) async {
        while let task = controller.localRegistrationTask {
            await task.value
        }
    }

    private func makeSignedInWithLocalServer(
        registration: ServerCloudRegistration = ServerCloudRegistration(connected: false)
    ) async -> (CloudAccountController, FakeCloudClient, FakeLocalServerClient) {
        let client = FakeCloudClient()
        client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
        let (controller, _, _) = makeController(
            client: client,
            environmentCloud: CodevisorAppVariant.DevelopmentCloud(
                url: URL(string: "http://127.0.0.1:8787")!,
                token: "dev-token"
            )
        )
        let localServer = FakeLocalServerClient(registration: registration)
        controller.localServerClient = localServer
        await controller.signInWithDevelopmentAccount()
        await awaitLocalRegistration(controller)
        return (controller, client, localServer)
    }

    @Test("Signing in registers the local machine on the account")
    func signInRegistersLocalMachine() async throws {
        let (controller, client, localServer) = await makeSignedInWithLocalServer()

        #expect(localServer.connects.count == 1)
        #expect(localServer.connects.first?.serverURL == controller.serverURL)
        #expect(localServer.connects.first?.sessionToken == "dev-token")
        // The successful registration re-refreshes the account machine list
        // so the new machine shows up everywhere immediately.
        #expect(client.machineTokens.count >= 2)
    }

    @Test("An existing registration (CLI or dev-provisioned) is left alone")
    func signInLeavesExistingRegistrationAlone() async throws {
        let (_, _, localServer) = await makeSignedInWithLocalServer(
            registration: ServerCloudRegistration(
                connected: true,
                deviceId: "cli-device",
                state: "connected",
                managedBy: "external"
            )
        )

        #expect(localServer.connects.isEmpty)
    }

    @Test("Registration retries on the next refresh after a failed attempt")
    func registrationRetriesAfterFailure() async throws {
        let client = FakeCloudClient()
        client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
        let (controller, _, _) = makeController(
            client: client,
            environmentCloud: CodevisorAppVariant.DevelopmentCloud(
                url: URL(string: "http://127.0.0.1:8787")!,
                token: "dev-token"
            )
        )
        struct ServerStartingUp: Error {}
        let localServer = FakeLocalServerClient()
        localServer.connectError = ServerStartingUp()
        controller.localServerClient = localServer
        await controller.signInWithDevelopmentAccount()
        await awaitLocalRegistration(controller)
        #expect(localServer.disconnects == 0)

        localServer.connectError = nil
        await controller.refreshMachines()
        await awaitLocalRegistration(controller)
        #expect(localServer.connects.count == 1)
    }

    @Test("Sign-out deregisters an app-managed local machine and revokes it")
    func signOutDeregistersAppManagedMachine() async throws {
        let (controller, client, localServer) = await makeSignedInWithLocalServer()
        #expect(localServer.connects.count == 1)

        controller.signOut()
        await controller.localDeregistrationTask?.value

        #expect(localServer.disconnects == 1)
        // The machine's api key is revoked with the pre-sign-out session.
        #expect(client.removals == ["local-device-1"])
    }

    @Test("Sign-out leaves CLI-managed registrations connected")
    func signOutLeavesExternalRegistrationAlone() async throws {
        let (controller, client, localServer) = await makeSignedInWithLocalServer(
            registration: ServerCloudRegistration(
                connected: true,
                deviceId: "cli-device",
                state: "connected",
                managedBy: "external"
            )
        )

        controller.signOut()
        await controller.localDeregistrationTask?.value

        #expect(localServer.disconnects == 0)
        #expect(client.removals.isEmpty)
    }

    @Test("GitHub sign-in is offered only when the server advertises it")
    func gitHubProviderGating() async throws {
        let devOnly = FakeCloudClient()
        devOnly.discoverResult = .success(
            CloudInstanceInfo(service: "codevisor-cloud", instance: "Dev", authProviders: ["dev"])
        )
        let (controller, _, _) = makeController(client: devOnly)
        #expect(controller.supportsGitHubSignIn) // unknown yet → assume GitHub
        await controller.bootstrap()
        #expect(!controller.supportsGitHubSignIn)

        let withGitHub = FakeCloudClient()
        withGitHub.discoverResult = .success(
            CloudInstanceInfo(
                service: "codevisor-cloud",
                instance: "Cloud",
                authProviders: ["github", "dev"]
            )
        )
        let (hosted, _, _) = makeController(client: withGitHub)
        await hosted.bootstrap()
        #expect(hosted.supportsGitHubSignIn)

        // Discovery failure keeps the assume-GitHub default.
        let offline = CloudAccountController(
            clientFactory: { _ in OfflineCloudClient() },
            credentialStore: InMemoryCloudCredentialStore(),
            environmentCloud: nil
        )
        await offline.bootstrap()
        #expect(offline.supportsGitHubSignIn)
    }

    @Test("Bootstrap clears a token the server no longer recognizes")
    func bootstrapClearsInvalidToken() async throws {
        let (controller, _, store) = makeController(
            store: InMemoryCloudCredentialStore(token: "stale")
        )

        await controller.bootstrap()

        #expect(controller.state == .signedOut)
        #expect(try store.token() == nil)
    }

    @Test("Bootstrap keeps the token when the server is unreachable")
    func bootstrapKeepsTokenOnNetworkFailure() async throws {
        // session(token:) returning nil means "server answered: no session"
        // and clears; a thrown error means "couldn't ask" and must not.
        let store = InMemoryCloudCredentialStore(token: "kept")
        let controller = CloudAccountController(
            clientFactory: { _ in OfflineCloudClient() },
            credentialStore: store,
            environmentCloud: nil
        )

        await controller.bootstrap()

        #expect(controller.state == .signedOut)
        #expect(try store.token() == "kept")
    }

    @Test("Sign-in exchanges the one-time token and loads machines")
    func completeSignInHappyPath() async throws {
        let client = FakeCloudClient()
        client.verifyResult = .success("session-token")
        client.sessions["session-token"] = CloudSessionUser(userId: "u1", email: "me@example.com")
        client.machinesResult = .success([Self.machine("m1"), Self.machine("m2", online: false)])
        let (controller, _, store) = makeController(client: client)

        await controller.completeSignIn(ott: "ott-1")

        #expect(controller.state == .signedIn(userEmail: "me@example.com"))
        #expect(try store.token() == "session-token")
        #expect(controller.machines.map(\.deviceId) == ["m1", "m2"])
        #expect(controller.lastError == nil)
    }

    @Test("A failed one-time-token exchange signs out with an error")
    func completeSignInFailure() async throws {
        let client = FakeCloudClient()
        client.verifyResult = .failure(CloudAccountClientError.httpStatus(401))
        let (controller, _, store) = makeController(client: client)

        await controller.completeSignIn(ott: "expired")

        #expect(controller.state == .signedOut)
        #expect(try store.token() == nil)
        #expect(controller.lastError != nil)
    }

    @Test("Sign-out clears the token and machines but keeps the custom server")
    func signOutKeepsCustomServer() async throws {
        let client = FakeCloudClient()
        client.verifyResult = .success("session-token")
        client.sessions["session-token"] = CloudSessionUser(userId: "u1", email: "me@example.com")
        client.machinesResult = .success([Self.machine("m1")])
        let store = InMemoryCloudCredentialStore(serverURL: URL(string: "https://cloud.example.com")!)
        let (controller, _, _) = makeController(client: client, store: store)
        await controller.completeSignIn(ott: "ott-1")

        controller.signOut()

        #expect(controller.state == .signedOut)
        #expect(controller.machines.isEmpty)
        #expect(try store.token() == nil)
        #expect(try store.serverURL() == URL(string: "https://cloud.example.com")!)
    }

    @Test("Rename applies optimistically, calls the server, and refreshes")
    func renameMachine() async throws {
        let client = FakeCloudClient()
        client.verifyResult = .success("t")
        client.sessions["t"] = CloudSessionUser(userId: "u1", email: nil)
        client.machinesResult = .success([Self.machine("m1", name: "Old Name")])
        let (controller, _, _) = makeController(client: client)
        await controller.completeSignIn(ott: "ott")

        client.machinesResult = .success([Self.machine("m1", name: "Studio")])
        await controller.rename(deviceId: "m1", name: "  Studio  ")

        #expect(client.renames.count == 1)
        #expect(client.renames.first?.deviceId == "m1")
        #expect(client.renames.first?.name == "Studio")
        #expect(controller.machines.first?.name == "Studio")
    }

    @Test("Remove drops the machine optimistically and on the server")
    func removeMachine() async throws {
        let client = FakeCloudClient()
        client.verifyResult = .success("t")
        client.sessions["t"] = CloudSessionUser(userId: "u1", email: nil)
        client.machinesResult = .success([Self.machine("m1"), Self.machine("m2")])
        let (controller, _, _) = makeController(client: client)
        await controller.completeSignIn(ott: "ott")

        client.machinesResult = .success([Self.machine("m2")])
        await controller.remove(deviceId: "m1")

        #expect(client.removals == ["m1"])
        #expect(controller.machines.map(\.deviceId) == ["m2"])
    }

    @Test("Custom server validation rejects non-cloud instances")
    func customServerRejectsNonCloud() async throws {
        let client = FakeCloudClient()
        client.discoverResult = .success(CloudInstanceInfo(service: "some-other-service"))
        let (controller, _, store) = makeController(client: client)

        await #expect(throws: CloudAccountClientError.notACloudInstance) {
            try await controller.setCustomServer(URL(string: "https://not-cloud.example.com")!)
        }
        #expect(try store.serverURL() == nil)
        #expect(controller.serverURL == CloudAccountController.defaultServerURL)
    }

    @Test("A validated custom server is saved and the old session dropped")
    func customServerAcceptsCloudInstance() async throws {
        let client = FakeCloudClient()
        client.verifyResult = .success("t")
        client.sessions["t"] = CloudSessionUser(userId: "u1", email: "me@example.com")
        client.discoverResult = .success(
            CloudInstanceInfo(service: "codevisor-cloud", instance: "My Homelab")
        )
        let (controller, _, store) = makeController(client: client)
        await controller.completeSignIn(ott: "ott")

        try await controller.setCustomServer(URL(string: "https://cloud.example.com")!)

        #expect(try store.serverURL() == URL(string: "https://cloud.example.com")!)
        #expect(controller.customInstanceName == "My Homelab")
        #expect(controller.state == .signedOut)
        #expect(try store.token() == nil)

        // Clearing restores the default instance.
        try await controller.setCustomServer(nil)
        #expect(try store.serverURL() == nil)
        #expect(controller.customInstanceName == nil)
    }

    @Test("Sign-in URL percent-encodes the handoff redirect")
    func signInURLEncoding() {
        let (controller, _, _) = makeController()
        #expect(
            controller.signInURL(scheme: "codevisor-dev").absoluteString
                == "https://cloud.codevisor.dev/login/github?redirect=/auth/handoff%3Fapp%3Dcodevisor-dev"
        )

        let custom = makeController(
            store: InMemoryCloudCredentialStore(serverURL: URL(string: "https://cloud.example.com/")!)
        )
        #expect(
            custom.controller.signInURL(scheme: "codevisor").absoluteString
                == "https://cloud.example.com/login/github?redirect=/auth/handoff%3Fapp%3Dcodevisor"
        )
    }
}
