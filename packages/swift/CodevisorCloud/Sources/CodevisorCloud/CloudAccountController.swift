import CodevisorClient
import Foundation
import Observation

@MainActor
@Observable
public final class CloudAccountController {
  public static let defaultServerURL = URL(string: "https://cloud.codevisor.dev")!

  public internal(set) var state: CloudAccountState = .signedOut
  public internal(set) var machines: [CloudMachine] = []
  public private(set) var machinesWithChangedKeys: Set<String> = []
  public internal(set) var hasCompletedBootstrap = false
  public internal(set) var isRosterVerified = false
  public var lastError: String?
  public internal(set) var linkedProviders: Set<CloudSignInProvider>?
  var authenticationRevision: UInt64 = 0
  public internal(set) var authProviders: [String]?

  public var supportsGitHubSignIn: Bool {
    authProviders?.contains("github") ?? true
  }

  public var supportsAppleSignIn: Bool {
    authProviders?.contains("apple") == true
  }

  public var developmentAccountAvailable: Bool {
    authProviders?.contains("dev") == true && customServerURL == nil
  }

  public typealias ClientFactory = @Sendable (URL) -> any CloudAccountClienting
  public typealias HubConnectionFactory = @MainActor (URL, any CloudCredentialStore) -> CloudHubConnection

  let clientFactory: ClientFactory
  let credentialStore: any CloudCredentialStore
  let machineKeyPins: CloudMachineKeyPinCache
  private let environmentCloud: CodevisorAppVariant.DevelopmentCloud?
  private let hubConnectionFactory: HubConnectionFactory
  @ObservationIgnored private var hub: CloudHubConnection?
  public let directPaths: CloudDirectPathController
  private let loopbackPool = CloudLoopbackBridgePool()
  @ObservationIgnored public var onSignedOut: (() -> Void)?
  @ObservationIgnored public var onMachinesRefreshed: (() -> Void)?
  @ObservationIgnored public var onLocalMachineRegistrationResolved: ((String) -> Void)?
  @ObservationIgnored public var localServerClient: (any CodevisorServerClienting)?
  struct LocalRegistrationResolution: Sendable {
    let deviceId: String
    let didConnect: Bool
  }

  @ObservationIgnored var accountSyncRegistrations: [String: Task<Bool, Never>] = [:]
  @ObservationIgnored var localRegistrationTask: Task<LocalRegistrationResolution?, Never>?
  @ObservationIgnored var localDeregistrationTask: Task<Void, Never>?
  @ObservationIgnored private let presenceSleep: @Sendable (Duration) async throws -> Void
  @ObservationIgnored var presenceRefreshTask: Task<Void, Never>?
  @ObservationIgnored let retryClock: any Clock<Duration>
  @ObservationIgnored var validationTask: Task<Void, Never>?
  @ObservationIgnored var validationRetryTask: Task<Void, Never>?
  @ObservationIgnored var validationGeneration: UInt64 = 0
  @ObservationIgnored var validationFailures = 0
  @ObservationIgnored var cachedCredentials: StoredCredentials?
  @ObservationIgnored var credentialWriteGeneration: UInt64 = 0
  var credentialRevision: UInt64 = 0

  public init(
    clientFactory: @escaping ClientFactory = { CloudAccountClient(baseURL: $0) },
    credentialStore: any CloudCredentialStore,
    environmentCloud: CodevisorAppVariant.DevelopmentCloud? = CodevisorAppVariant.developmentCloud,
    hubConnectionFactory: @escaping HubConnectionFactory = { serverURL, store in
      CloudHubConnection(serverURL: serverURL, credentialStore: store)
    },
    directPaths: CloudDirectPathController? = nil,
    presenceSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    retryClock: any Clock<Duration> = ContinuousClock()
  ) {
    self.presenceSleep = presenceSleep
    self.retryClock = retryClock
    self.clientFactory = clientFactory
    self.credentialStore = credentialStore
    self.machineKeyPins = CloudMachineKeyPinCache(store: credentialStore)
    self.environmentCloud = environmentCloud
    self.hubConnectionFactory = hubConnectionFactory
    self.directPaths = directPaths ?? CloudDirectPathController(credentialStore: credentialStore)
  }

  public var serverURL: URL {
    customServerURL ?? environmentCloud?.url ?? Self.defaultServerURL
  }

  var client: any CloudAccountClienting {
    clientFactory(serverURL)
  }

  public func refreshAuthProviders() async {
    do {
      authProviders = try await client.discover().authProviders
    } catch {
      Log.cloud.error("Cloud discovery failed: \(String(describing: error), privacy: .public)")
    }
  }

  public func completeSignIn(ott: String) async {
    let client = client
    await adoptSession { try await client.verifyOneTimeToken(ott) }
  }

  public func signInWithDevelopmentAccount() async {
    guard developmentAccountAvailable else { return }
    let client = client
    await adoptSession { try await client.developmentLogin() }
  }

  func adoptSession(_ obtainToken: () async throws -> String) async {
    authenticationRevision &+= 1
    let revision = authenticationRevision
    let server = serverURL
    state = .validating
    linkedProviders = nil
    lastError = nil
    cancelSessionValidation()
    isRosterVerified = false
    let client = client
    do {
      let token = try await obtainToken()
      guard authenticationRevision == revision, serverURL == server else { return }
      await discardHubForCredentialChange()
      guard authenticationRevision == revision, serverURL == server else { return }
      try saveStoredToken(token)
      let user = (try? await client.session(token: token)) ?? nil
      guard authenticationRevision == revision, serverURL == server, storedToken == token else { return }
      state = .signedIn(userEmail: user?.email)
      if case let .failed(error) = await performMachineRefresh(), !Self.isSessionRejection(error) {
        scheduleSessionValidationRetry()
      }
    } catch {
      guard authenticationRevision == revision, serverURL == server else { return }
      Log.cloud.error("Cloud sign-in failed: \(String(describing: error), privacy: .public)")
      state = .signedOut
      lastError = error.localizedDescription
    }
  }

  public func signOut() {
    endSession(deregisterLocalMachine: true)
  }

  func sessionEnded() {
    endSession(deregisterLocalMachine: false)
  }

  private func endSession(deregisterLocalMachine: Bool) {
    authenticationRevision &+= 1
    linkedProviders = nil
    lastError = nil
    let token = storedToken
    let localClient = localServerClient
    let accountClient = client
    clearSessionCredential()
    discardSessionRosterAndTransports()
    if deregisterLocalMachine, let localClient {
      scheduleLocalMachineDeregistration(token: token, localClient: localClient, accountClient: accountClient)
    }
    refreshAuthProvidersIfUnknown()
    onSignedOut?()
  }

  private func clearSessionCredential() {
    localRegistrationTask?.cancel()
    localRegistrationTask = nil
    do {
      try removeStoredToken()
    } catch {
      Log.cloud.error("Failed to clear cloud token: \(String(describing: error), privacy: .public)")
    }
  }

  private func discardSessionRosterAndTransports() {
    machines = []
    cancelSessionValidation()
    isRosterVerified = false
    credentialStore.clearRoster()
    machinesWithChangedKeys = []
    state = .signedOut
    machineKeyPins.invalidate()
    presenceRefreshTask?.cancel()
    presenceRefreshTask = nil
    stopAllLoopbackBridges()
    directPaths.dropAll()
    if let hub {
      self.hub = nil
      Task { await hub.shutdown() }
    }
  }

  private func scheduleLocalMachineDeregistration(
    token: String?,
    localClient: any CodevisorServerClienting,
    accountClient: any CloudAccountClienting
  ) {
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

  private func discardHubForCredentialChange() async {
    machineKeyPins.invalidate()
    stopAllLoopbackBridges()
    directPaths.dropAll()
    presenceRefreshTask?.cancel()
    presenceRefreshTask = nil
    guard let hub else { return }
    self.hub = nil
    await hub.shutdown()
  }

  public func refreshMachines() async {
    await performMachineRefresh()
  }

  @discardableResult
  func performMachineRefresh() async -> MachineRefreshOutcome {
    guard state.isSignedIn, let token = storedToken else { return .skipped }
    let pinGeneration = machineKeyPins.generation
    do {
      try await machineKeyPins.prepare()
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
            Log.cloud.debug(
              "Post-registration machine refresh failed: \(String(describing: error), privacy: .public)"
            )
          }
        }
      }
      guard state.isSignedIn, machineKeyPins.generation == pinGeneration, !Task.isCancelled else {
        return .skipped
      }
      try reconcileMachineKeyPins(refreshedMachines)
      machines = refreshedMachines
      didVerifyRoster()
      if let hub {
        await hub.reconcileAuthoritativeMachines(refreshedMachines)
      }
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
      return .succeeded
    } catch is CancellationError {
      return .skipped
    } catch {
      Log.cloud.error("Cloud machine refresh failed: \(String(describing: error), privacy: .public)")
      lastError = error.localizedDescription
      if case CloudAccountClientError.httpStatus(401) = error {
        sessionEnded()
      }
      return .failed(error)
    }
  }

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

  public func remove(deviceId: String) async {
    guard let token = storedToken else { return }
    machines.removeAll { $0.deviceId == deviceId }
    stopLoopbackBridge(deviceId: deviceId)
    directPaths.drop(deviceId: deviceId)
    removeMachineKeyPin(deviceId: deviceId)
    do {
      try await client.removeMachine(deviceId: deviceId, token: token)
    } catch {
      Log.cloud.error("Cloud machine removal failed: \(String(describing: error), privacy: .public)")
      lastError = error.localizedDescription
    }
    await refreshMachines()
  }

  public func setCustomServer(_ url: URL?) async throws {
    guard let url else {
      signOut()
      try saveCustomServerURL(nil)
      try clearMachineKeyPins()
      return
    }
    let info = try await clientFactory(url).discover()
    guard info.service == CloudInstanceInfo.expectedService else {
      throw CloudAccountClientError.notACloudInstance
    }
    signOut()
    try saveCustomServerURL(url)
    authProviders = info.authProviders
    try clearMachineKeyPins()
  }

  public func hubConnection() -> CloudHubConnection? {
    guard state.isSignedIn else { return nil }
    if let hub { return hub }
    let hub = hubConnectionFactory(serverURL, credentialStore)
    self.hub = hub
    Task { [weak self] in
      guard let self else { return }
      await hub.setMachinesChangedHandler { [weak self] transportMachines in
        guard let self else { return }
        Task { @MainActor in
          self.reconcilePresence(with: transportMachines)
        }
      }
      await hub.setTunnelConfigHandler { [weak self] config in
        Task { @MainActor in
          guard let self else { return }
          self.directPaths.onTunnelConfigured = { [weak self] in self?.reconcileDirectPaths() }
          self.directPaths.configureTunnel(config)
        }
      }
      await hub.connect()
    }
    return hub
  }

  func reconcilePresence(with transportMachines: [CloudMachine]) {
    guard state.isSignedIn else { return }
    guard presenceDiffers(from: transportMachines) else { return }
    guard presenceRefreshTask == nil else { return }
    let sleep = presenceSleep
    presenceRefreshTask = Task { [weak self] in
      try? await sleep(.milliseconds(300))
      guard let self, !Task.isCancelled else { return }
      self.presenceRefreshTask = nil
      await self.refreshMachines()
    }
  }

  private func presenceDiffers(from transportMachines: [CloudMachine]) -> Bool {
    func reach(_ machine: CloudMachine) -> String {
      "\(machine.online)|\(machine.tunnel?.endpointId ?? "")"
    }
    let known = Dictionary(
      machines.map { ($0.deviceId, reach($0)) },
      uniquingKeysWith: { first, _ in first }
    )
    return transportMachines.contains(where: { known[$0.deviceId] != reach($0) })
  }

  public func reconnectHub() async {
    guard state.isSignedIn else { return }
    directPaths.networkChanged()
    if let hub {
      await hub.reconnect()
    }
    await refreshMachines()
    Task { [weak self] in await self?.recoverLoopbackBridges() }
  }

  private func stopLoopbackBridge(deviceId: String) {
    loopbackPool.remove(deviceId)
  }

  private func stopAllLoopbackBridges() {
    loopbackPool.removeAll()
  }

  private func recoverLoopbackBridges() async {
    let active = Set(loopbackPool.machineIds)
    await withTaskGroup(of: Void.self) { group in
      for machine in machines where active.contains(machine.deviceId) {
        group.addTask { _ = await self.recoverLoopbackBridge(for: machine) }
      }
    }
  }

  private func pruneLoopbackBridges() {
    let known = Set(machines.map(\.deviceId))
    for deviceId in loopbackPool.machineIds where !known.contains(deviceId) {
      stopLoopbackBridge(deviceId: deviceId)
    }
  }
}

extension CloudAccountController {
  func reconcileMachineKeyPins(_ machines: [CloudMachine]) throws {
    guard var pins = machineKeyPins.pins else { throw CancellationError() }
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
      try machineKeyPins.save(pins)
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

  func verifiedMachineKey(for machine: CloudMachine) -> String? {
    guard let pinned = machineKeyPins.pins?[machine.deviceId] else { return nil }
    return pinned == machine.publicKey ? machine.publicKey : nil
  }

  public func trustChangedMachineKey(deviceId: String) {
    guard let machine = machines.first(where: { $0.deviceId == deviceId }) else { return }
    guard var pins = machineKeyPins.pins else { return }
    pins[deviceId] = machine.publicKey
    guard persistMachineKeyPins(pins) else { return }
    machinesWithChangedKeys.remove(deviceId)
    Log.cloud.log("User re-trusted the changed key for machine \(deviceId, privacy: .public)")
  }

  func removeMachineKeyPin(deviceId: String) {
    guard var pins = machineKeyPins.pins else { return }
    guard pins.removeValue(forKey: deviceId) != nil else { return }
    guard persistMachineKeyPins(pins) else { return }
    machinesWithChangedKeys.remove(deviceId)
  }

  func clearMachineKeyPins() throws {
    try machineKeyPins.save([:])
    machinesWithChangedKeys = []
  }

  @discardableResult
  private func persistMachineKeyPins(_ pins: [String: String]) -> Bool {
    do {
      try machineKeyPins.save(pins)
      return true
    } catch {
      Log.cloud.error(
        "Failed to persist machine key pins: \(String(describing: error), privacy: .public)")
      return false
    }
  }
}

extension CloudAccountController: CloudMachineProviding {
  public var isCloudSignedIn: Bool { state.isSignedIn }

  public var cloudMachines: [CloudMachine] { machines }

  public var isCloudRosterVerified: Bool { isRosterVerified }

  public func relayServerConfig(for machine: CloudMachine) -> CodevisorServerConfig? {
    guard hubConnection() != nil, verifiedMachineKey(for: machine) != nil else {
      return nil
    }
    return tunnelServerConfig(
      deviceId: machine.deviceId,
      baseURL: loopbackBaseURL(for: machine) ?? CodevisorMachine.cloudPlaceholderBaseURL)
  }

  public func loopbackBaseURL(for machine: CloudMachine) -> URL? {
    guard state.isSignedIn, hubConnection() != nil,
      let key = verifiedMachineKey(for: machine)
    else { return nil }
    return loopbackPool.baseURL(
      for: machine.deviceId, key: key,
      endpoint: machineTransport(forDeviceId: machine.deviceId))
  }

  public func loopbackRevision(for machine: CloudMachine) -> UInt64 {
    loopbackPool.revision(for: machine.deviceId)
  }

  public func recoverLoopbackBridge(for machine: CloudMachine) async -> Bool {
    guard state.isSignedIn, hubConnection() != nil,
      let key = verifiedMachineKey(for: machine)
    else { return false }
    return await loopbackPool.recover(
      for: machine.deviceId, key: key,
      endpoint: machineTransport(forDeviceId: machine.deviceId))
  }
}
