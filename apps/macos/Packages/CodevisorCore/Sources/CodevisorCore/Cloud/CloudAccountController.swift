import Foundation
import Observation

public enum CloudAccountState: Equatable, Sendable {
    case signedOut
    case validating
    case signedIn(userEmail: String?)

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

/// The cloud account feature's brain: sign-in state, the machine list, and
/// custom-server selection. All networking goes through `clientFactory` so
/// tests can inject a fake client; the session token and custom server URL
/// live in the injected `CloudCredentialStore`.
@MainActor
@Observable
public final class CloudAccountController {
    public static let defaultServerURL = URL(string: "https://cloud.codevisor.dev")!

    public private(set) var state: CloudAccountState = .signedOut
    public private(set) var machines: [CloudMachine] = []
    public var lastError: String?
    /// The validated instance name of the current custom server, for display
    /// in Settings. Only populated after a successful `setCustomServer`.
    public private(set) var customInstanceName: String?
    /// Auth providers the current server advertises (/.well-known/codevisor).
    /// nil until discovery answers — treat unknown as "assume GitHub" so the
    /// hosted instance's button never flickers away on a slow network.
    public private(set) var authProviders: [String]?

    /// Whether to offer the GitHub sign-in button: true when the server
    /// advertises it, or while its capabilities are still unknown.
    public var supportsGitHubSignIn: Bool {
        authProviders?.contains("github") ?? true
    }

    /// A dev-cloud session from `bun run dev` is available for one-tap
    /// sign-in. Development instances only.
    public var developmentAccountAvailable: Bool {
        environmentCloud?.token != nil && customServerURL == nil
    }

    public typealias ClientFactory = @Sendable (URL) -> any CloudAccountClienting
    public typealias HubConnectionFactory = @MainActor (URL, any CloudCredentialStore) -> CloudHubConnection

    private let clientFactory: ClientFactory
    private let credentialStore: any CloudCredentialStore
    private let environmentCloud: CodevisorAppVariant.DevelopmentCloud?
    private let hubConnectionFactory: HubConnectionFactory
    /// The account's one relay connection, created lazily while signed in and
    /// torn down on sign-out / server switch.
    @ObservationIgnored private var hub: CloudHubConnection?
    /// Per-machine loopback bridges (real 127.0.0.1 addresses that forward
    /// onto the relay), created lazily on first `loopbackBaseURL` access and
    /// torn down with the account. Keyed by cloud device id; the pinned
    /// public key detects re-provisioned machines whose bridge is stale.
    @ObservationIgnored private var loopbackBridges: [String: (bridge: CloudRelayLoopbackBridge, publicKey: String)] = [:]
    /// Ports of listening bridges. Observable so machine lists synthesized
    /// from cloud presence recompute their base URLs when a bridge comes up.
    private var loopbackPorts: [String: UInt16] = [:]
    /// Fired after a local sign-out (including a revoked session detected by
    /// refreshMachines) so the machine list can drop cloud selections.
    @ObservationIgnored public var onSignedOut: (() -> Void)?
    /// Fired after the machine list refreshes, so consumers deduplicating
    /// against it (MachineController.allMachines) can reconcile selections.
    @ObservationIgnored public var onMachinesRefreshed: (() -> Void)?

    public init(
        clientFactory: @escaping ClientFactory = { CloudAccountClient(baseURL: $0) },
        credentialStore: any CloudCredentialStore,
        environmentCloud: CodevisorAppVariant.DevelopmentCloud? = CodevisorAppVariant.developmentCloud,
        hubConnectionFactory: @escaping HubConnectionFactory = { serverURL, store in
            CloudHubConnection(serverURL: serverURL, credentialStore: store)
        }
    ) {
        self.clientFactory = clientFactory
        self.credentialStore = credentialStore
        self.environmentCloud = environmentCloud
        self.hubConnectionFactory = hubConnectionFactory
    }

    /// A user-entered custom server wins, then the dev cloud from `bun run
    /// dev`, then the hosted default instance.
    public var serverURL: URL {
        customServerURL ?? environmentCloud?.url ?? Self.defaultServerURL
    }

    public var customServerURL: URL? {
        (try? credentialStore.serverURL()) ?? nil
    }

    private var storedToken: String? {
        (try? credentialStore.token()) ?? nil
    }

    private var client: any CloudAccountClienting {
        clientFactory(serverURL)
    }

    /// The browser sign-in entry point: `/login/github` starts the OAuth flow
    /// server-side and 302s straight to GitHub's consent page (no interstitial
    /// button page), with a redirect that lands on the app-handoff page, which
    /// bounces back into the app via `<scheme>://cloud-auth?ott=…`. Instances
    /// without GitHub configured redirect to the /login page instead. The
    /// redirect value is percent-encoded so its own `?app=` query survives.
    public func signInURL(scheme: String) -> URL {
        let base = serverURL.absoluteString.hasSuffix("/")
            ? String(serverURL.absoluteString.dropLast())
            : serverURL.absoluteString
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "?=&+")
        let redirect = "/auth/handoff?app=\(scheme)"
        let encoded = redirect.addingPercentEncoding(withAllowedCharacters: allowed) ?? redirect
        return URL(string: "\(base)/login/github?redirect=\(encoded)") ?? serverURL
    }

    /// Boot: validate whatever token is stored. An invalid token signs out
    /// and clears it; a network failure keeps the token for the next attempt.
    /// The dev-cloud session is NOT adopted automatically — development
    /// builds offer it as an explicit "Use Development Account" action
    /// (`signInWithDevelopmentAccount`).
    public func bootstrap() async {
        await refreshAuthProviders()
        guard let token = storedToken else {
            state = .signedOut
            return
        }
        state = .validating
        do {
            guard let user = try await client.session(token: token) else {
                try? credentialStore.removeToken()
                state = .signedOut
                return
            }
            state = .signedIn(userEmail: user.email)
            await refreshMachines()
        } catch {
            // Unreachable server ≠ revoked session: keep the token so the
            // next launch (or refresh) can try again.
            Log.cloud.error("Cloud session validation failed: \(String(describing: error), privacy: .public)")
            state = .signedOut
            lastError = error.localizedDescription
        }
    }

    /// Asks the current server which sign-in providers it offers, so the UI
    /// only shows buttons that can work (a dev instance without GitHub
    /// credentials advertises ["dev"] only). Best-effort: unreachable keeps
    /// the previous answer (or the assume-GitHub default).
    public func refreshAuthProviders() async {
        do {
            authProviders = try await client.discover().authProviders
        } catch {
            Log.cloud.error("Cloud discovery failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Development builds only: sign in with the dev-cloud session that
    /// `bun run dev` provisioned, as an explicit user action (never adopted
    /// automatically).
    public func signInWithDevelopmentAccount() async {
        guard let devToken = environmentCloud?.token else { return }
        state = .validating
        lastError = nil
        do {
            guard let user = try await client.session(token: devToken) else {
                state = .signedOut
                lastError = "The development account is not available right now."
                return
            }
            try credentialStore.saveToken(devToken)
            state = .signedIn(userEmail: user.email)
            await refreshMachines()
        } catch {
            state = .signedOut
            lastError = error.localizedDescription
        }
    }

    /// Finishes the browser flow: exchanges the handoff's one-time token for
    /// a session token, stores it, and loads the account's machines.
    public func completeSignIn(ott: String) async {
        state = .validating
        lastError = nil
        let client = client
        do {
            let token = try await client.verifyOneTimeToken(ott)
            try credentialStore.saveToken(token)
            let user = (try? await client.session(token: token)) ?? nil
            state = .signedIn(userEmail: user?.email)
            await refreshMachines()
        } catch {
            Log.cloud.error("Cloud sign-in failed: \(String(describing: error), privacy: .public)")
            state = .signedOut
            lastError = error.localizedDescription
        }
    }

    /// Signs out locally: the token is cleared (a custom server choice is
    /// kept), the machine list emptied, and the relay connection torn down.
    public func signOut() {
        do {
            try credentialStore.removeToken()
        } catch {
            Log.cloud.error("Failed to clear cloud token: \(String(describing: error), privacy: .public)")
        }
        machines = []
        state = .signedOut
        stopAllLoopbackBridges()
        if let hub {
            self.hub = nil
            Task { await hub.shutdown() }
        }
        onSignedOut?()
    }

    public func refreshMachines() async {
        guard state.isSignedIn, let token = storedToken else { return }
        do {
            machines = try await client.machines(token: token)
            pruneLoopbackBridges()
            lastError = nil
            onMachinesRefreshed?()
        } catch {
            Log.cloud.error("Cloud machine refresh failed: \(String(describing: error), privacy: .public)")
            lastError = error.localizedDescription
            if case CloudAccountClientError.httpStatus(401) = error {
                // The session was revoked elsewhere — reflect it instead of
                // showing a stale signed-in pane forever.
                signOut()
            }
        }
    }

    /// Optimistically renames, then confirms against the server.
    public func rename(deviceId: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let token = storedToken else { return }
        if let index = machines.firstIndex(where: { $0.deviceId == deviceId }) {
            machines[index].name = trimmed
        }
        do {
            try await client.rename(deviceId: deviceId, name: trimmed, token: token)
        } catch {
            Log.cloud.error("Cloud machine rename failed: \(String(describing: error), privacy: .public)")
            lastError = error.localizedDescription
        }
        await refreshMachines()
    }

    /// Optimistically removes, then confirms against the server.
    public func remove(deviceId: String) async {
        guard let token = storedToken else { return }
        machines.removeAll { $0.deviceId == deviceId }
        stopLoopbackBridge(deviceId: deviceId)
        do {
            try await client.removeMachine(deviceId: deviceId, token: token)
        } catch {
            Log.cloud.error("Cloud machine removal failed: \(String(describing: error), privacy: .public)")
            lastError = error.localizedDescription
        }
        await refreshMachines()
    }

    /// Points the app at a self-hosted instance (nil restores the default).
    /// The server is validated via its discovery document before anything is
    /// saved; switching servers always signs out of the previous session —
    /// its token means nothing on the new instance.
    public func setCustomServer(_ url: URL?) async throws {
        guard let url else {
            signOut()
            try credentialStore.saveServerURL(nil)
            customInstanceName = nil
            return
        }
        let info = try await clientFactory(url).discover()
        guard info.service == CloudInstanceInfo.expectedService else {
            throw CloudAccountClientError.notACloudInstance
        }
        signOut()
        try credentialStore.saveServerURL(url)
        customInstanceName = info.instance
        authProviders = info.authProviders
    }

    /// The account's relay hub connection, created on first use while signed
    /// in. One connection serves every cloud machine.
    public func hubConnection() -> CloudHubConnection? {
        guard state.isSignedIn else { return nil }
        if let hub { return hub }
        let hub = hubConnectionFactory(serverURL, credentialStore)
        self.hub = hub
        return hub
    }

    // MARK: - Loopback bridges

    /// Starts (idempotently) this machine's loopback bridge and publishes its
    /// port once the listener is up. The synchronous caller sees nil until
    /// then; the observable `loopbackPorts` mutation re-runs machine-list
    /// synthesis when the real address becomes available.
    private func ensureLoopbackBridge(for machine: CloudMachine) {
        if let existing = loopbackBridges[machine.deviceId] {
            // A re-provisioned machine (fresh keys under the same device id)
            // needs a fresh bridge — the old one pins the old public key.
            guard existing.publicKey != machine.publicKey else { return }
            existing.bridge.stop()
            loopbackBridges[machine.deviceId] = nil
            Task { [weak self] in self?.loopbackPorts[machine.deviceId] = nil }
        }
        guard let hub = hubConnection() else { return }
        let endpoint = CloudRelayEndpoint(
            hub: hub,
            machineDeviceId: machine.deviceId,
            machinePublicKey: machine.publicKey
        )
        let bridge = CloudRelayLoopbackBridge(endpoint: endpoint)
        loopbackBridges[machine.deviceId] = (bridge, machine.publicKey)
        let deviceId = machine.deviceId
        Task { [weak self] in
            do {
                let port = try await bridge.start()
                guard let self, self.loopbackBridges[deviceId]?.bridge === bridge else {
                    bridge.stop()
                    return
                }
                self.loopbackPorts[deviceId] = port
            } catch {
                Log.cloud.error("Cloud loopback bridge failed to start: \(String(describing: error), privacy: .public)")
                guard let self, self.loopbackBridges[deviceId]?.bridge === bridge else { return }
                self.loopbackBridges[deviceId] = nil
            }
        }
    }

    private func stopLoopbackBridge(deviceId: String) {
        loopbackBridges.removeValue(forKey: deviceId)?.bridge.stop()
        loopbackPorts[deviceId] = nil
    }

    private func stopAllLoopbackBridges() {
        for entry in loopbackBridges.values {
            entry.bridge.stop()
        }
        loopbackBridges = [:]
        loopbackPorts = [:]
    }

    /// Drops bridges for machines that no longer exist on the account.
    private func pruneLoopbackBridges() {
        let known = Set(machines.map(\.deviceId))
        for deviceId in loopbackBridges.keys where !known.contains(deviceId) {
            stopLoopbackBridge(deviceId: deviceId)
        }
    }
}

// MARK: - CloudMachineProviding

/// Cloud machines join the unified machine list: MachineController reads the
/// account's machines here and asks for relay-backed server configs when one
/// is selected.
extension CloudAccountController: CloudMachineProviding {
    public var isCloudSignedIn: Bool { state.isSignedIn }

    public var cloudMachines: [CloudMachine] { machines }

    public func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig? {
        guard let hub = hubConnection() else { return nil }
        let endpoint = CloudRelayEndpoint(
            hub: hub,
            machineDeviceId: machine.deviceId,
            machinePublicKey: machine.publicKey
        )
        // The transports tunnel in-process; the baseURL matters only to
        // consumers that hand it to external processes (terminal proxy), so
        // it becomes the machine's real loopback address once bridged.
        return CodevisorServerConfig(
            baseURL: loopbackBaseURL(for: machine) ?? CodevisorMachine.cloudPlaceholderBaseURL,
            bearerToken: nil,
            requestTransport: CloudRelayRequestTransport(endpoint: endpoint),
            webSocketTransport: CloudRelayWebSocketTransport(endpoint: endpoint)
        )
    }

    public func loopbackBaseURL(for machine: CloudMachine) -> URL? {
        guard state.isSignedIn else { return nil }
        ensureLoopbackBridge(for: machine)
        guard let port = loopbackPorts[machine.deviceId] else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }
}
