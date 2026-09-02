import CodevisorClient
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
  /// Machines whose presented public key conflicts with the TOFU pin taken
  /// on first sight. Relay channels to them are refused (`relayServerConfig`
  /// and the loopback bridge return nil) until the user explicitly re-trusts
  /// via `trustChangedMachineKey` — the hub is not trusted for key
  /// continuity, so a silent key swap here would defeat the end-to-end
  /// encryption. UI surfaces these as "machine key changed".
  public private(set) var machinesWithChangedKeys: Set<String> = []
  /// False until the app has checked any persisted account session and, when
  /// valid, loaded its first machine snapshot. Callers must not interpret an
  /// empty `machines` array as an authoritative "no machines" result before
  /// this becomes true.
  public private(set) var hasCompletedBootstrap = false
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

  /// The cloud instance itself advertises dev auth (`authProviders`
  /// contains "dev") — the local dev Worker does, hosted instances never.
  /// A user-chosen custom server hides it: they are talking to their own
  /// instance, not the dev one.
  public var developmentAccountAvailable: Bool {
    authProviders?.contains("dev") == true && customServerURL == nil
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
  /// Direct LAN pipes per machine, probed after each refresh. Channel opens
  /// go through `SwitchingChannelTransport`, which prefers a live verified
  /// direct pipe and falls back to the relay.
  public let directPaths: CloudDirectPathController
  /// Per-machine loopback bridges (real 127.0.0.1 addresses that forward
  /// onto the relay), created lazily on first `loopbackBaseURL` access and
  /// torn down with the account. Keyed by cloud device id; the pinned
  /// public key detects re-provisioned machines whose bridge is stale.
  @ObservationIgnored private var loopbackBridges: [String: (bridge: CloudRelayLoopbackBridge, publicKey: String)] =
    [:]
  /// Ports of listening bridges. Observable so machine lists synthesized
  /// from cloud presence recompute their base URLs when a bridge comes up.
  private var loopbackPorts: [String: UInt16] = [:]
  /// Fired after a local sign-out (including a revoked session detected by
  /// refreshMachines) so the machine list can drop cloud selections.
  @ObservationIgnored public var onSignedOut: (() -> Void)?
  /// Fired after the machine list refreshes, so consumers deduplicating
  /// against it (MachineController.allMachines) can reconcile selections.
  @ObservationIgnored public var onMachinesRefreshed: (() -> Void)?
  /// Fired after the embedded server's cloud identity is known, before a
  /// refreshed roster is published. Consumers use this as an identity
  /// barrier so the local machine's relay twin can never begin navigation
  /// sync under a second fleet id.
  @ObservationIgnored public var onLocalMachineRegistrationResolved: ((String) -> Void)?
  /// The embedded local server's client, when this platform runs one
  /// (macOS). While signed in, the account controller registers that server
  /// on the account via its /v1/cloud routes so this machine appears on the
  /// user's other devices without a separate `codevisor auth login` — and
  /// tears the registration down again on sign-out (app-managed ones only).
  @ObservationIgnored public var localServerClient: (any CodevisorServerClienting)?
  struct LocalRegistrationResolution: Sendable {
    let deviceId: String
    let didConnect: Bool
  }

  /// Reentrancy guard for registration: one probe/connect in flight at a
  /// time; failed attempts retry on the next refresh. Internal so tests can
  /// await completion.
  @ObservationIgnored var localRegistrationTask: Task<LocalRegistrationResolution?, Never>?
  /// The best-effort sign-out deregistration, kept so tests can await it.
  @ObservationIgnored var localDeregistrationTask: Task<Void, Never>?
  /// A debounced roster refresh triggered by a hub presence push whose view
  /// disagrees with `machines`. Coalesces bursts (a welcome delivers the
  /// whole fleet) into one REST fetch.
  @ObservationIgnored var presenceRefreshTask: Task<Void, Never>?

  public init(
    clientFactory: @escaping ClientFactory = { CloudAccountClient(baseURL: $0) },
    credentialStore: any CloudCredentialStore,
    environmentCloud: CodevisorAppVariant.DevelopmentCloud? = CodevisorAppVariant.developmentCloud,
    hubConnectionFactory: @escaping HubConnectionFactory = { serverURL, store in
      CloudHubConnection(serverURL: serverURL, credentialStore: store)
    },
    directPaths: CloudDirectPathController? = nil
  ) {
    self.clientFactory = clientFactory
    self.credentialStore = credentialStore
    self.environmentCloud = environmentCloud
    self.hubConnectionFactory = hubConnectionFactory
    self.directPaths = directPaths ?? CloudDirectPathController(credentialStore: credentialStore)
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

  /// Whether launch still needs the network-backed account restoration path.
  /// Signed-out installs have no cloud machines to recover and can render
  /// their locally persisted machine state immediately.
  public var isRestoringPersistedSession: Bool {
    !hasCompletedBootstrap && storedToken != nil
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
    let base =
      serverURL.absoluteString.hasSuffix("/")
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
  /// Development builds sign into the dev cloud exactly as production
  /// signs into the hosted one — no session ever arrives via environment.
  public func bootstrap() async {
    guard !hasCompletedBootstrap else { return }
    defer {
      if !Task.isCancelled {
        hasCompletedBootstrap = true
      }
    }
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

  /// Finishes the browser flow: exchanges the handoff's one-time token for
  /// a session token, stores it, and loads the account's machines.
  public func completeSignIn(ott: String) async {
    let client = client
    await adoptSession { try await client.verifyOneTimeToken(ott) }
  }

  /// Dev-only: signs in as the cloud's seeded development user. Only the
  /// credential's origin differs from the browser flow — the session is
  /// real and everything after it (storage, machine list, local machine
  /// registration) is the production path.
  public func signInWithDevelopmentAccount() async {
    guard developmentAccountAvailable else { return }
    let client = client
    await adoptSession { try await client.developmentLogin() }
  }

  /// The one sign-in completion: obtain a session token, store it, load
  /// the account. Every sign-in flow funnels through here so they cannot
  /// diverge.
  private func adoptSession(_ obtainToken: () async throws -> String) async {
    state = .validating
    lastError = nil
    let client = client
    do {
      let token = try await obtainToken()
      await discardHubForCredentialChange()
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
    // Capture before the token is cleared: deregistering this machine
    // needs the session to revoke its api key on the account.
    let token = storedToken
    let localClient = localServerClient
    let accountClient = client
    localRegistrationTask?.cancel()
    localRegistrationTask = nil
    do {
      try credentialStore.removeToken()
    } catch {
      Log.cloud.error("Failed to clear cloud token: \(String(describing: error), privacy: .public)")
    }
    machines = []
    // Pins survive sign-out (continuity knowledge belongs to the device,
    // not the session); only the visible flags reset with the list.
    machinesWithChangedKeys = []
    state = .signedOut
    presenceRefreshTask?.cancel()
    presenceRefreshTask = nil
    stopAllLoopbackBridges()
    directPaths.dropAll()
    if let hub {
      self.hub = nil
      Task { await hub.shutdown() }
    }
    // Best-effort: a registration this app created follows its account
    // session, so signing out disconnects the local machine and revokes
    // its credential. CLI (`codevisor auth login`) and dev-provisioned
    // registrations are external — leave them alone.
    if let localClient {
      localDeregistrationTask = Task {
        do {
          let registration = try await localClient.cloudRegistration()
          guard registration.managedBy == "app", let deviceId = registration.deviceId else {
            return
          }
          try await localClient.disconnectCloud()
          if let token {
            try? await accountClient.removeMachine(deviceId: deviceId, token: token)
          }
          Log.cloud.log("Deregistered this machine from the cloud account on sign-out")
        } catch {
          Log.cloud.error(
            "Local machine cloud deregistration failed: \(String(describing: error), privacy: .public)")
        }
      }
    }
    onSignedOut?()
  }

  /// A hub owns an immutable snapshot of the account credentials. Replacing
  /// a token therefore replaces the hub too; otherwise a reconnect could
  /// keep authenticating with the previous account's cached session.
  private func discardHubForCredentialChange() async {
    stopAllLoopbackBridges()
    directPaths.dropAll()
    presenceRefreshTask?.cancel()
    presenceRefreshTask = nil
    guard let hub else { return }
    self.hub = nil
    await hub.shutdown()
  }

  public func refreshMachines() async {
    guard state.isSignedIn, let token = storedToken else { return }
    do {
      let accountClient = client
      var refreshedMachines = try await accountClient.machines(token: token)
      if let localClient = localServerClient {
        let registrationTask = beginLocalMachineRegistration(
          token: token,
          localClient: localClient
        )
        if let resolution = await registrationTask.value,
          resolution.didConnect
        {
          do {
            refreshedMachines = try await accountClient.machines(token: token)
          } catch {
            // The first roster is still authoritative. Identity
            // resolution already prevents the newly registered
            // local twin from joining the fleet until a later
            // refresh sees it.
            Log.cloud.debug(
              "Post-registration machine refresh failed: \(String(describing: error), privacy: .public)"
            )
          }
        }
      }
      machines = refreshedMachines
      if let hub {
        // Feed the authoritative REST snapshot back into the relay's
        // channel gate. This heals a missed/reordered presence frame
        // without replacing an otherwise healthy hub connection.
        await hub.reconcileAuthoritativeMachines(refreshedMachines)
      }
      reconcileMachineKeyPins()
      #if DEBUG || NAVIGATION_DIAGNOSTICS
        let machineSummary = machines.map { machine in
          "\(machine.name){id=\(machine.deviceId),online=\(machine.online)}"
        }.joined(separator: ",")
        Log.cloud.notice(
          "CLOUDDBG machines.refresh server=\(self.serverURL.absoluteString, privacy: .public) count=\(self.machines.count) machines=[\(machineSummary, privacy: .public)]"
        )
      #endif
      pruneLoopbackBridges()
      reconcileDirectPaths()
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

  /// Registers the machine this app runs on with the signed-in account, so
  /// it appears on the user's other devices without `codevisor auth login`.
  /// No-ops while signed out, on platforms without an embedded server
  /// (iOS), when the local server is unreachable (it retries on the next
  /// machine refresh), or when the machine already holds a registration —
  /// its own from a prior sign-in, the CLI, or dev auto-provisioning.
  public func registerLocalMachineIfNeeded() {
    guard state.isSignedIn, let token = storedToken, let localClient = localServerClient else {
      return
    }
    guard localRegistrationTask == nil else { return }
    let registrationTask = beginLocalMachineRegistration(
      token: token,
      localClient: localClient
    )
    Task { [weak self] in
      guard let resolution = await registrationTask.value,
        resolution.didConnect,
        !Task.isCancelled,
        let self
      else { return }
      await self.refreshMachines()
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
    directPaths.drop(deviceId: deviceId)
    // A removed machine's pin goes with it: re-adding is a fresh pairing.
    removeMachineKeyPin(deviceId: deviceId)
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
      clearMachineKeyPins()
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
    // Pins belong to an instance's device-id namespace; a different
    // server means a fresh TOFU world (sign-out alone keeps them, since
    // re-signing into the same account must keep continuity knowledge).
    clearMachineKeyPins()
  }

  /// The account's relay hub connection, created on first use while signed
  /// in. One connection serves every cloud machine.
  public func hubConnection() -> CloudHubConnection? {
    guard state.isSignedIn else { return nil }
    if let hub { return hub }
    let hub = hubConnectionFactory(serverURL, credentialStore)
    self.hub = hub
    // Presence pushed by the hub keeps the UI roster live: a machine
    // signed in on another device appears here the moment it connects,
    // instead of waiting for the next foreground or a settings poll.
    Task { [weak self] in
      guard let self else { return }
      await hub.setMachinesChangedHandler { [weak self] transportMachines in
        guard let self else { return }
        Task { @MainActor in
          self.reconcilePresence(with: transportMachines)
        }
      }
    }
    return hub
  }

  /// Compares the hub's live presence view against the UI roster and, on
  /// disagreement (an unknown machine appeared, or an online flag flipped),
  /// schedules one authoritative refresh. Deliberately refresh-based: the
  /// REST fetch stays the single writer of `machines`, so key pinning, twin
  /// dedup, and direct-path reconciliation keep their one home in
  /// `refreshMachines()` — the push is only a trigger, never a source.
  func reconcilePresence(with transportMachines: [CloudMachine]) {
    guard state.isSignedIn else { return }
    let known = Dictionary(
      machines.map { ($0.deviceId, $0.online) },
      uniquingKeysWith: { first, _ in first }
    )
    // `known[...]` is nil for an unknown device, which never equals a
    // Bool — one comparison covers both "new machine" and "flipped".
    guard transportMachines.contains(where: { known[$0.deviceId] != $0.online }) else {
      return
    }
    guard presenceRefreshTask == nil else { return }
    presenceRefreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard let self, !Task.isCancelled else { return }
      self.presenceRefreshTask = nil
      await self.refreshMachines()
    }
  }

  /// Replaces an existing relay socket after the app returns to the
  /// foreground. Channel owners observe the close and reopen from their
  /// durable cursors; the account refresh keeps machine-list presence in
  /// step with the new hub welcome.
  public func reconnectHub() async {
    guard state.isSignedIn else { return }
    // Every transport is suspect at this point (suspension, network
    // handoff), including the direct LAN pipes: a half-open pipe is
    // caught by its own heartbeat within ~15s, but recovery requests
    // race that detection and burn their full timeout against a dead
    // socket — one such timeout is enough to fail the selected machine.
    // Drop the pipes now; the reconnected relay carries traffic
    // immediately, and the machine refresh below re-probes the LAN.
    directPaths.dropAll()
    if let hub {
      await hub.reconnect()
    }
    await refreshMachines()
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
    // TOFU: a machine presenting a key that conflicts with its pin gets
    // no bridge at all until the user explicitly re-trusts it.
    guard let hub = hubConnection(), let verifiedKey = verifiedMachineKey(for: machine) else {
      return
    }
    let endpoint = machineTransport(for: machine, verifiedKey: verifiedKey, hub: hub)
    let bridge = CloudRelayLoopbackBridge(endpoint: endpoint)
    loopbackBridges[machine.deviceId] = (bridge, verifiedKey)
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

// MARK: - Machine key pinning (TOFU)

extension CloudAccountController {
  /// Reconciles the machine list against the pinned keys: unknown machines
  /// are pinned on first sight; a machine whose presented key conflicts with
  /// its pin is flagged and cut off from relay channels until re-trusted.
  func reconcileMachineKeyPins() {
    var pins = (try? credentialStore.pinnedMachineKeys()) ?? [:]
    var changed = Set<String>()
    var dirty = false
    for machine in machines {
      if let pinned = pins[machine.deviceId] {
        if pinned != machine.publicKey {
          changed.insert(machine.deviceId)
        }
      } else {
        pins[machine.deviceId] = machine.publicKey
        dirty = true
      }
    }
    if dirty {
      persistMachineKeyPins(pins)
    }
    for deviceId in changed.subtracting(machinesWithChangedKeys) {
      Log.cloud.error(
        "Machine \(deviceId, privacy: .public) presented a key that conflicts with its pin; refusing relay channels until the user re-trusts it"
      )
    }
    if machinesWithChangedKeys != changed {
      machinesWithChangedKeys = changed
    }
  }

  /// The key to open channels with, iff it matches the TOFU pin (pinning it
  /// on first sight). nil = the key changed; no channel may open.
  func verifiedMachineKey(for machine: CloudMachine) -> String? {
    var pins = (try? credentialStore.pinnedMachineKeys()) ?? [:]
    guard let pinned = pins[machine.deviceId] else {
      pins[machine.deviceId] = machine.publicKey
      persistMachineKeyPins(pins)
      return machine.publicKey
    }
    return pinned == machine.publicKey ? machine.publicKey : nil
  }

  /// Explicit user consent to a machine's new key — the "key changed, trust
  /// anyway" action. Re-pins to the currently presented key and lifts the
  /// channel refusal. Never called automatically.
  public func trustChangedMachineKey(deviceId: String) {
    guard let machine = machines.first(where: { $0.deviceId == deviceId }) else { return }
    var pins = (try? credentialStore.pinnedMachineKeys()) ?? [:]
    pins[deviceId] = machine.publicKey
    persistMachineKeyPins(pins)
    machinesWithChangedKeys.remove(deviceId)
    Log.cloud.log("User re-trusted the changed key for machine \(deviceId, privacy: .public)")
  }

  func removeMachineKeyPin(deviceId: String) {
    var pins = (try? credentialStore.pinnedMachineKeys()) ?? [:]
    guard pins.removeValue(forKey: deviceId) != nil else { return }
    persistMachineKeyPins(pins)
    machinesWithChangedKeys.remove(deviceId)
  }

  func clearMachineKeyPins() {
    persistMachineKeyPins([:])
    machinesWithChangedKeys = []
  }

  private func persistMachineKeyPins(_ pins: [String: String]) {
    do {
      try credentialStore.savePinnedMachineKeys(pins)
    } catch {
      Log.cloud.error(
        "Failed to persist machine key pins: \(String(describing: error), privacy: .public)")
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
    // TOFU: no relay config for a machine whose key conflicts with its
    // pin — every channel would be opened against the imposter key.
    guard let hub = hubConnection(), let verifiedKey = verifiedMachineKey(for: machine) else {
      return nil
    }
    let endpoint = machineTransport(for: machine, verifiedKey: verifiedKey, hub: hub)
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
