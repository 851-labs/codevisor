import CodevisorClient
import Foundation
import Observation

@MainActor
@Observable
public final class CloudAccountController {
  public static let defaultServerURL = URL(string: "https://cloud.codevisor.dev")!

  public internal(set) var state: CloudAccountState = .signedOut
  public internal(set) var machines: [CloudMachine] = []
  public var lastError: String?
  public internal(set) var linkedProviders: Set<CloudSignInProvider>?
  var authenticationRevision: UInt64 = 0

  public var authProviders: [String]? { providerDiscovery.advertised }
  public var supportsGitHubSignIn: Bool { providerDiscovery.offersGitHub }
  public var supportsAppleSignIn: Bool { providerDiscovery.offersApple }
  public var hasCompletedBootstrap: Bool { validation.hasCompletedBootstrap }
  public var isRosterVerified: Bool { validation.isRosterVerified }
  public var machinesWithChangedKeys: Set<String> { machineKeyPins.changedKeys }
  public var customServerURL: URL? { credentialCache.current.serverURL }
  var storedToken: String? { credentialCache.current.token }

  public var developmentAccountAvailable: Bool {
    providerDiscovery.offersDevelopmentAccount && customServerURL == nil
  }

  public typealias ClientFactory = @Sendable (URL) -> any CloudAccountClienting
  public typealias HubConnectionFactory = @MainActor (URL, any CloudCredentialStore) -> CloudHubConnection

  let clientFactory: ClientFactory
  let credentialStore: any CloudCredentialStore
  let credentialCache: CloudCredentialCache
  let machineKeyPins: CloudMachineKeyPinCache
  let validation: CloudSessionValidation
  let presence: CloudPresenceRefresh
  private let providerDiscovery = CloudAuthProviders()
  let localRegistration = CloudLocalMachineRegistration()
  private let hubLink: CloudHubLink
  private let environmentCloud: CodevisorAppVariant.DevelopmentCloud?
  public let directPaths: CloudDirectPathController
  private let loopbackPool = CloudLoopbackBridgePool()
  @ObservationIgnored public var onSignedOut: (() -> Void)?
  @ObservationIgnored public var onMachinesRefreshed: (() -> Void)?
  @ObservationIgnored public var onLocalMachineRegistrationResolved: ((String) -> Void)?
  @ObservationIgnored public var localServerClient: (any CodevisorServerClienting)?
  @ObservationIgnored var accountSyncRegistrations: [String: Task<Bool, Never>] = [:]

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
    self.presence = CloudPresenceRefresh(sleep: presenceSleep)
    self.clientFactory = clientFactory
    self.credentialStore = credentialStore
    let credentialCache = CloudCredentialCache(store: credentialStore)
    let machineKeyPins = CloudMachineKeyPinCache(store: credentialStore)
    self.credentialCache = credentialCache
    self.machineKeyPins = machineKeyPins
    self.validation = CloudSessionValidation(
      clock: retryClock, credentials: credentialCache, pins: machineKeyPins, rosterStore: credentialStore)
    self.environmentCloud = environmentCloud
    self.hubLink = CloudHubLink(factory: hubConnectionFactory)
    self.directPaths = directPaths ?? CloudDirectPathController(credentialStore: credentialStore)
  }

  public var serverURL: URL {
    customServerURL ?? environmentCloud?.url ?? Self.defaultServerURL
  }

  var client: any CloudAccountClienting {
    clientFactory(serverURL)
  }

  public func refreshAuthProviders() async {
    await providerDiscovery.refresh(using: client)
  }

  public func bootstrap() async {
    await validation.bootstrap(for: self)
  }

  public func retryIfUnverified() async {
    await validation.retryIfUnverified(for: self)
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
    let attempt = startSignInAttempt()
    let client = client
    do {
      let token = try await obtainToken()
      guard isCurrent(attempt) else { return }
      try await signIn(with: token, attempt: attempt, client: client)
    } catch {
      guard isCurrent(attempt) else { return }
      signInFailed(error)
    }
  }

  public func signOut() {
    endSession(deregisterLocalMachine: true)
  }

  func sessionEnded() {
    endSession(deregisterLocalMachine: false)
  }

  public func refreshMachines() async {
    await performMachineRefresh()
  }

  @discardableResult
  func performMachineRefresh() async -> MachineRefreshOutcome {
    guard state.isSignedIn, let token = storedToken else { return .skipped }
    let pinGeneration = machineKeyPins.generation
    do {
      let refreshed = try await fetchMachines(token: token)
      guard refreshIsCurrent(pinGeneration: pinGeneration) else { return .skipped }
      try await adoptRefreshedMachines(refreshed)
      return .succeeded
    } catch is CancellationError {
      return .skipped
    } catch {
      return machineRefreshFailed(error)
    }
  }

  public func registerLocalMachineIfNeeded() {
    guard state.isSignedIn, let token = storedToken, let localClient = localServerClient else {
      return
    }
    localRegistration.registerIfIdle(for: self, token: token, localClient: localClient)
  }

  public func updateMachine(deviceId: String, name: String, icon: String?) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let token = storedToken else { return }
    renameLocally(deviceId: deviceId, name: trimmed, icon: icon)
    do {
      try await client.updateMachine(deviceId: deviceId, name: trimmed, icon: icon, token: token)
    } catch {
      Log.cloud.error("Cloud machine update failed: \(String(describing: error), privacy: .public)")
      lastError = error.localizedDescription
    }
    await refreshMachines()
  }

  public func remove(deviceId: String) async {
    guard let token = storedToken else { return }
    forgetLocally(deviceId: deviceId)
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
      try credentialCache.saveServerURL(nil)
      try machineKeyPins.clear()
      return
    }
    let info = try await cloudInstance(at: url)
    signOut()
    try credentialCache.saveServerURL(url)
    providerDiscovery.adopt(info.authProviders)
    try machineKeyPins.clear()
  }

  public func hubConnection() -> CloudHubConnection? {
    guard state.isSignedIn else { return nil }
    return hubLink.connection(for: self)
  }

  func reconcilePresence(with transportMachines: [CloudMachine]) {
    presence.reconcile(transportMachines, for: self)
  }

  public func reconnectHub() async {
    guard state.isSignedIn else { return }
    directPaths.networkChanged()
    await hubLink.reconnect()
    await refreshMachines()
    Task { [weak self] in await self?.recoverLoopbackBridges() }
  }

  func verifiedMachineKey(for machine: CloudMachine) -> String? {
    machineKeyPins.verifiedKey(for: machine)
  }

  func tunnelConfigured(_ config: CloudTunnelConfig) {
    directPaths.onTunnelConfigured = { [weak self] in self?.reconcileDirectPaths() }
    directPaths.configureTunnel(config)
  }

  public func signInURL(scheme: String, provider: CloudSignInProvider = .github) -> URL {
    CloudAuthLinks.signIn(server: serverURL, scheme: scheme, provider: provider)
  }

  public func connectAccountURL(provider: CloudSignInProvider, scheme: String) async -> URL? {
    guard state.isSignedIn, let token = storedToken else { return nil }
    let server = serverURL
    do {
      let ott = try await client.generateOneTimeToken(token: token)
      guard storedToken == token, serverURL == server else { return nil }
      return CloudAuthLinks.connectAccount(server: server, provider: provider, scheme: scheme, ott: ott)
    } catch {
      guard storedToken == token, serverURL == server else { return nil }
      lastError = error.localizedDescription
      return nil
    }
  }

  public func deleteAccount() async {
    guard state.isSignedIn, let token = storedToken else { return }
    let server = serverURL
    lastError = nil
    do {
      try await client.deleteAccount(token: token)
      guard storedToken == token, serverURL == server else { return }
      signOut()
    } catch {
      guard storedToken == token, serverURL == server else { return }
      lastError = error.localizedDescription
    }
  }

  public func trustChangedMachineKey(deviceId: String) {
    guard let machine = machines.first(where: { $0.deviceId == deviceId }) else { return }
    machineKeyPins.trust(machine)
  }

  private struct SignInAttempt {
    let revision: UInt64
    let server: URL
  }

  private func startSignInAttempt() -> SignInAttempt {
    authenticationRevision &+= 1
    let attempt = SignInAttempt(revision: authenticationRevision, server: serverURL)
    state = .validating
    linkedProviders = nil
    lastError = nil
    validation.unverify()
    return attempt
  }

  private func isCurrent(_ attempt: SignInAttempt) -> Bool {
    authenticationRevision == attempt.revision && serverURL == attempt.server
  }

  private func signIn(with token: String, attempt: SignInAttempt, client: any CloudAccountClienting) async throws {
    await discardHubForCredentialChange()
    guard isCurrent(attempt) else { return }
    try credentialCache.saveToken(token)
    let user = (try? await client.session(token: token)) ?? nil
    guard isCurrent(attempt), storedToken == token else { return }
    state = .signedIn(userEmail: user?.email)
    if await performMachineRefresh().needsValidationRetry {
      validation.scheduleRetry(for: self)
    }
  }

  private func signInFailed(_ error: any Error) {
    Log.cloud.error("Cloud sign-in failed: \(String(describing: error), privacy: .public)")
    state = .signedOut
    lastError = error.localizedDescription
  }

  private func endSession(deregisterLocalMachine: Bool) {
    authenticationRevision &+= 1
    linkedProviders = nil
    lastError = nil
    let token = storedToken
    let localClient = localServerClient
    let accountClient = client
    clearSessionCredential()
    discardSessionRoster()
    discardSessionTransports()
    if deregisterLocalMachine, let localClient {
      localRegistration.deregister(token: token, localClient: localClient, accountClient: accountClient)
    }
    providerDiscovery.refreshIfUnknown(for: self)
    onSignedOut?()
  }

  private func clearSessionCredential() {
    localRegistration.cancel()
    do {
      try credentialCache.removeToken()
    } catch {
      Log.cloud.error("Failed to clear cloud token: \(String(describing: error), privacy: .public)")
    }
  }

  private func discardSessionRoster() {
    machines = []
    validation.discardRoster()
    machineKeyPins.forgetChangedKeys()
    state = .signedOut
  }

  private func discardSessionTransports() {
    machineKeyPins.invalidate()
    presence.cancel()
    loopbackPool.removeAll()
    directPaths.dropAll()
    hubLink.shutDownInBackground()
  }

  private func discardHubForCredentialChange() async {
    machineKeyPins.invalidate()
    loopbackPool.removeAll()
    directPaths.dropAll()
    presence.cancel()
    await hubLink.shutDown()
  }

  private func fetchMachines(token: String) async throws -> [CloudMachine] {
    try await machineKeyPins.prepare()
    let accountClient = client
    let fetched = try await accountClient.machines(token: token)
    guard let localClient = localServerClient else { return fetched }
    let registration = localRegistration.begin(for: self, token: token, localClient: localClient)
    guard let resolution = await registration.value, resolution.didConnect else { return fetched }
    return await refetchMachines(token: token, accountClient: accountClient) ?? fetched
  }

  private func refetchMachines(token: String, accountClient: any CloudAccountClienting) async -> [CloudMachine]? {
    do {
      return try await accountClient.machines(token: token)
    } catch {
      Log.cloud.debug(
        "Post-registration machine refresh failed: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  private var currentRoster: CachedRoster {
    CachedRoster(serverURL: serverURL.absoluteString, userEmail: state.userEmail, machines: machines)
  }

  private func refreshIsCurrent(pinGeneration: UInt64) -> Bool {
    state.isSignedIn && machineKeyPins.generation == pinGeneration && !Task.isCancelled
  }

  private func adoptRefreshedMachines(_ refreshed: [CloudMachine]) async throws {
    try machineKeyPins.reconcileChangedKeys(refreshed)
    machines = refreshed
    validation.rosterVerified(currentRoster)
    await hubLink.reconcileAuthoritativeMachines(refreshed)
    logRefreshedMachines()
    loopbackPool.removeAll(except: Set(machines.map(\.deviceId)))
    reconcileDirectPaths()
    lastError = nil
    onMachinesRefreshed?()
  }

  private func logRefreshedMachines() {
    #if DEBUG || NAVIGATION_DIAGNOSTICS
      let machineSummary = machines.map { machine in
        "\(machine.name){id=\(machine.deviceId),online=\(machine.online)}"
      }.joined(separator: ",")
      Log.cloud.notice(
        "CLOUDDBG machines.refresh server=\(self.serverURL.absoluteString, privacy: .public) count=\(self.machines.count) machines=[\(machineSummary, privacy: .public)]"
      )
    #endif
  }

  private func machineRefreshFailed(_ error: any Error) -> MachineRefreshOutcome {
    Log.cloud.error("Cloud machine refresh failed: \(String(describing: error), privacy: .public)")
    lastError = error.localizedDescription
    if CloudSessionValidation.isSessionRejection(error) {
      sessionEnded()
    }
    return .failed(error)
  }

  private func renameLocally(deviceId: String, name: String, icon: String?) {
    guard let index = machines.firstIndex(where: { $0.deviceId == deviceId }) else { return }
    machines[index].name = name
    if let icon { machines[index].icon = icon }
  }

  private func forgetLocally(deviceId: String) {
    machines.removeAll { $0.deviceId == deviceId }
    loopbackPool.remove(deviceId)
    directPaths.drop(deviceId: deviceId)
    machineKeyPins.removePin(deviceId: deviceId)
  }

  private func cloudInstance(at url: URL) async throws -> CloudInstanceInfo {
    let info = try await clientFactory(url).discover()
    guard info.service == CloudInstanceInfo.expectedService else {
      throw CloudAccountClientError.notACloudInstance
    }
    return info
  }

  private func recoverLoopbackBridges() async {
    let active = Set(loopbackPool.machineIds)
    await withTaskGroup(of: Void.self) { group in
      for machine in machines where active.contains(machine.deviceId) {
        group.addTask { _ = await self.recoverLoopbackBridge(for: machine) }
      }
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
