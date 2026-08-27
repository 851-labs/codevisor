import Foundation
import Testing
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

@MainActor
@Suite("CloudAccountController")
struct CloudAccountControllerTests {
    @Test("Server URL resolution: custom beats dev cloud beats default")
    func serverURLResolution() throws {
        let dev = CodevisorAppVariant.DevelopmentCloud(url: URL(string: "http://127.0.0.1:8787")!)

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

    @Test("Bootstrap with a dev cloud URL but no stored session stays signed out")
    func bootstrapStaysSignedOutWithoutSession() async throws {
        let client = FakeCloudClient()
        client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
        let (controller, _, store) = makeController(
            client: client,
            environmentCloud: CodevisorAppVariant.DevelopmentCloud(
                url: URL(string: "http://127.0.0.1:8787")!
            )
        )

        await controller.bootstrap()

        #expect(controller.state == .signedOut)
        #expect(try store.token() == nil)
    }

    /// Drains chained registration attempts (a successful connect re-refreshes
    /// the machine list, which re-probes and finds the registration in place).
    private func awaitLocalRegistration(_ controller: CloudAccountController) async {
        while let task = controller.localRegistrationTask {
            await task.value
        }
    }

    /// A controller signed in the production way — a stored session
    /// validated at boot — with a local server attached.
    private func makeSignedInWithLocalServer(
        registration: ServerCloudRegistration = ServerCloudRegistration(connected: false)
    ) async -> (CloudAccountController, FakeCloudClient, FakeLocalServerClient) {
        let client = FakeCloudClient()
        client.sessions["dev-token"] = CloudSessionUser(userId: "u1", email: "dev@example.com")
        let (controller, _, store) = makeController(
            client: client,
            environmentCloud: CodevisorAppVariant.DevelopmentCloud(
                url: URL(string: "http://127.0.0.1:8787")!
            )
        )
        let localServer = FakeLocalServerClient(registration: registration)
        controller.localServerClient = localServer
        try? store.saveToken("dev-token")
        await controller.bootstrap()
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
        let (controller, _, store) = makeController(
            client: client,
            environmentCloud: CodevisorAppVariant.DevelopmentCloud(
                url: URL(string: "http://127.0.0.1:8787")!
            )
        )
        struct ServerStartingUp: Error {}
        let localServer = FakeLocalServerClient()
        localServer.connectError = ServerStartingUp()
        controller.localServerClient = localServer
        // Signed in the production way: a stored session validated at boot.
        try store.saveToken("dev-token")
        await controller.bootstrap()
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
        #expect(controller.supportsGitHubSignIn)  // unknown yet → assume GitHub
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

    @Test("Persisted cloud machines remain unresolved until bootstrap completes")
    func persistedSessionRestorationState() async throws {
        let client = FakeCloudClient()
        client.sessions["persisted"] = CloudSessionUser(userId: "u1", email: "me@example.com")
        client.machinesResult = .success([testMachine("m1")])
        let (controller, _, _) = makeController(
            client: client,
            store: InMemoryCloudCredentialStore(token: "persisted")
        )

        #expect(controller.isRestoringPersistedSession)
        #expect(!controller.hasCompletedBootstrap)
        #expect(controller.machines.isEmpty)

        await controller.bootstrap()

        #expect(!controller.isRestoringPersistedSession)
        #expect(controller.hasCompletedBootstrap)
        #expect(controller.state == .signedIn(userEmail: "me@example.com"))
        #expect(controller.machines.map(\.deviceId) == ["m1"])
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
        client.machinesResult = .success([testMachine("m1"), testMachine("m2", online: false)])
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
        client.machinesResult = .success([testMachine("m1")])
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
        client.machinesResult = .success([testMachine("m1", name: "Old Name")])
        let (controller, _, _) = makeController(client: client)
        await controller.completeSignIn(ott: "ott")

        client.machinesResult = .success([testMachine("m1", name: "Studio")])
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
        client.machinesResult = .success([testMachine("m1"), testMachine("m2")])
        let (controller, _, _) = makeController(client: client)
        await controller.completeSignIn(ott: "ott")

        client.machinesResult = .success([testMachine("m2")])
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

    // MARK: - Machine key pinning (TOFU)

    @Test("Machine keys are pinned on first sight")
    func machineKeysPinnedOnFirstSight() async throws {
        let (controller, _, store) = await makeSignedIn(machines: [
            testMachine("m1"), testMachine("m2"),
        ])

        #expect(try store.pinnedMachineKeys() == ["m1": "pk_m1", "m2": "pk_m2"])
        #expect(controller.machinesWithChangedKeys.isEmpty)
        #expect(controller.relayServerConfig(for: testMachine("m1")) != nil)
    }

    @Test("A changed machine key is flagged and cut off from relay channels")
    func changedMachineKeyIsRefused() async throws {
        let (controller, client, store) = await makeSignedIn(machines: [
            testMachine("m1"), testMachine("m2"),
        ])

        // The hub now presents a different key for m1 — a substitution unless
        // the user says otherwise.
        let swapped = testMachine("m1", publicKey: "pk_attacker")
        client.machinesResult = .success([swapped, testMachine("m2")])
        await controller.refreshMachines()

        #expect(controller.machinesWithChangedKeys == ["m1"])
        #expect(controller.relayServerConfig(for: swapped) == nil)
        #expect(controller.loopbackBaseURL(for: swapped) == nil)
        // The pin itself is untouched, and the unchanged machine is unaffected.
        #expect(try store.pinnedMachineKeys()["m1"] == "pk_m1")
        #expect(controller.relayServerConfig(for: testMachine("m2")) != nil)
    }

    @Test("Re-trusting a changed key is explicit and restores connectivity")
    func trustChangedMachineKey() async throws {
        let (controller, client, store) = await makeSignedIn(machines: [testMachine("m1")])
        let swapped = testMachine("m1", publicKey: "pk_new")
        client.machinesResult = .success([swapped])
        await controller.refreshMachines()
        #expect(controller.relayServerConfig(for: swapped) == nil)

        controller.trustChangedMachineKey(deviceId: "m1")

        #expect(controller.machinesWithChangedKeys.isEmpty)
        #expect(try store.pinnedMachineKeys()["m1"] == "pk_new")
        #expect(controller.relayServerConfig(for: swapped) != nil)
    }

    @Test("Removing a machine drops its pin, so re-adding is a fresh pairing")
    func removeMachineDropsPin() async throws {
        let (controller, client, store) = await makeSignedIn(machines: [testMachine("m1")])

        client.machinesResult = .success([])
        await controller.remove(deviceId: "m1")
        #expect(try store.pinnedMachineKeys()["m1"] == nil)

        // The device id returns with a different key: first sight again.
        let readded = testMachine("m1", publicKey: "pk_fresh")
        client.machinesResult = .success([readded])
        await controller.refreshMachines()
        #expect(controller.machinesWithChangedKeys.isEmpty)
        #expect(try store.pinnedMachineKeys()["m1"] == "pk_fresh")
    }

    @Test("Switching servers clears the pins — a different TOFU world")
    func customServerClearsPins() async throws {
        let (controller, client, store) = await makeSignedIn(machines: [testMachine("m1")])
        #expect(try store.pinnedMachineKeys() == ["m1": "pk_m1"])

        client.discoverResult = .success(
            CloudInstanceInfo(service: "codevisor-cloud", instance: "Homelab")
        )
        try await controller.setCustomServer(URL(string: "https://cloud.example.com")!)

        #expect(try store.pinnedMachineKeys() == [:])
        #expect(controller.machinesWithChangedKeys.isEmpty)
    }
}
