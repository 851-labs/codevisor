import Foundation
import Observation

@MainActor
@Observable
public final class MachineController {
  public internal(set) var registry: MachineRegistry
  public var serverUpdateChannel: ServerUpdateChannel = .stable

  public typealias ClientFactory = @MainActor (CodevisorMachine) -> any CodevisorServerClienting

  let store: any PersistenceStore
  let projectList: ProjectListModel
  let workspaceSync: WorkspaceSyncModel?
  let localServer: (any LocalServerControlling)?
  let injectedClientFactory: ClientFactory?
  let requestGate: ServerRequestGate
  private let key = "machines"
  let updatePollInterval: Duration
  let updatePollAttempts: Int
  let updateScheduler: ServerUpdateScheduler
  let preparationSleep: @Sendable (Duration) async throws -> Void
  let preparationRetryBaseDelay: Duration
  let navigationClock: any Clock<Duration>
  let connections: MachineConnections
  let catalog: MachineCatalog
  @ObservationIgnored public var onHarnessLifecycleChanged: ((String) -> Void)?
  @ObservationIgnored public var onHarnessAuthChanged: ((String) -> Void)?
  @ObservationIgnored public var onHarnessNotice: ((ServerHarnessNotice) -> Void)?
  @ObservationIgnored public var onPluginStateChanged: ((String) -> Void)?
  @ObservationIgnored public var onMcpStateChanged: ((String) -> Void)?
  @ObservationIgnored public var onBotsChanged: ((String) -> Void)?
  @ObservationIgnored public var onPluginUpdated: ((String, String) -> Void)?
  @ObservationIgnored public var onSyncChanged: ((String, ServerSyncDocument) -> Void)?
  @ObservationIgnored public var onMachineConnected: ((String) -> Void)?
  @ObservationIgnored public var onSessionStateChanged: ((ChatSession, Int?) -> Void)?
  public init(
    store: any PersistenceStore,
    projectList: ProjectListModel,
    workspaceSync: WorkspaceSyncModel? = nil,
    localServer: (any LocalServerControlling)? = nil,
    clientFactory: ClientFactory? = nil,
    updatePollInterval: Duration = .seconds(2),
    updatePollAttempts: Int = 90,
    updateScheduler: ServerUpdateScheduler = .continuous,
    preparationSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    preparationRetryBaseDelay: Duration = .seconds(1),
    navigationClock: any Clock<Duration> = ContinuousClock(),
    reconnectNoticeDelay: Duration = .seconds(5),
    reconnectNoticeScheduler: SessionConnectionRecoveryScheduler = .continuous
  ) {
    let requestGate = ServerRequestGate()
    let connections = MachineConnections(
      reconnectNoticeDelay: reconnectNoticeDelay, reconnectNoticeScheduler: reconnectNoticeScheduler)
    self.connections = connections
    self.catalog = MachineCatalog(
      includesLocalMachine: localServer != nil || clientFactory != nil, connections: connections)
    self.store = store
    self.projectList = projectList
    self.workspaceSync = workspaceSync
    self.localServer = localServer
    self.requestGate = requestGate
    self.injectedClientFactory = clientFactory
    self.updatePollInterval = updatePollInterval
    self.updatePollAttempts = updatePollAttempts
    self.updateScheduler = updateScheduler
    self.preparationSleep = preparationSleep
    self.preparationRetryBaseDelay = preparationRetryBaseDelay
    self.navigationClock = navigationClock
    if let data = store.loadData(forKey: "machines") {
      do {
        registry = try JSONDecoder().decode(MachineRegistry.self, from: data).normalized()
      } catch {
        registry = MachineRegistry()
        handleCorruptPayload(
          store: store,
          key: "machines",
          data: data,
          error: error,
          reportTitle: "Couldn't Read Your Machine List",
          reportMessage: "The file was unreadable. A backup was saved in Codevisor's data folder."
        )
      }
    } else {
      registry = MachineRegistry()
    }
    for machine in machines {
      if clientFactory == nil {
        beginWaiting(for: machine.id, reason: .starting)
      } else {
        markReady(for: machine.id)
      }
    }
    configureNavigationStore()
  }

  public var cloudProvider: (any CloudMachineProviding)? {
    get { catalog.cloudProvider }
    set { catalog.cloudProvider = newValue }
  }

  var connectionsById: [String: MachineConnection] { connections.byId }
  var persistenceStore: any PersistenceStore { store }

  public var selectedMachineId: String {
    registry.selectedMachineId
  }

  public var selectedMachine: CodevisorMachine {
    machine(for: registry.selectedMachineId) ?? allMachines.first ?? CodevisorMachine.local
  }

  public var machines: [CodevisorMachine] { catalog.machines }
  public var allMachines: [CodevisorMachine] { catalog.allMachines }
  public var cloudOnlyMachines: [CloudMachine] { catalog.cloudOnlyMachines }
  public var localCloudMachine: CloudMachine? { catalog.localCloudMachine }
  public func machine(for id: String) -> CodevisorMachine? { catalog.machine(for: id) }
  public func cloudMachine(forMachineId id: String) -> CloudMachine? { catalog.cloudMachine(forMachineId: id) }
  public var chatMachines: [CodevisorMachine] { allMachines.filter { !isSandbox($0.id) } }

  public func isSandbox(_ id: String) -> Bool { cloudMachine(forMachineId: id)?.ephemeral != nil }
  public func chatMachine(for id: String) -> CodevisorMachine? { isSandbox(id) ? nil : machine(for: id) }
  public func icon(for cloud: CloudMachine) -> MachineIcon { catalog.icon(for: cloud) }
  public func canonicalComposerMachineId(for id: String) -> String? { catalog.canonicalComposerMachineId(for: id) }
  public func fleetMachineName(for serverId: String) -> String? { catalog.fleetMachineName(for: serverId) }
  public func machineId(forSyncKey key: String) -> String? { catalog.machineId(forSyncKey: key) }
  public func syncKey(forMachineId id: String) -> String? { catalog.syncKey(forMachineId: id) }
  public func fleetName(forSyncKey key: String) -> String { catalog.fleetName(forSyncKey: key) }

  public var statusByMachineId: [String: MachineStatus] { connections.statusById }
  public var availabilityByMachineId: [String: ServerAvailability] { connections.availabilityById }
  public var navigationSyncStateByMachineId: [String: NavigationSyncState] { connections.navigationSyncStateById }
  public func availability(for machineId: String) -> ServerAvailability { connections.availability(for: machineId) }

  public func updatePauseSubject(
    machineId: String, sessionId: UUID?, harnessId: String?
  ) -> ServerUpdatePauseSubject? {
    connections.updatePauseSubject(machineId: machineId, sessionId: sessionId, harnessId: harnessId)
  }

  public func showsReconnectNotice(for machineId: String) -> Bool {
    connections.showsReconnectNotice(for: machineId)
  }

  private func applySelection(_ id: String) {
    guard let machine = machine(for: id) else { return }
    registry.selectedMachineId = machine.id
    persist()
  }

  private func autoSelectPreferredMachineIfNeeded() {
    guard localServer == nil,
      selectedMachineId == CodevisorMachine.local.id,
      let candidate = preferredAutoSelectionCandidate()
    else { return }
    applySelection(candidate.id)
  }

  private func preferredAutoSelectionCandidate() -> CodevisorMachine? {
    let candidates = allMachines.filter { !$0.isLocal }
    return candidates.first { isMachineOnline($0) } ?? candidates.first
  }

  private func isMachineOnline(_ machine: CodevisorMachine) -> Bool {
    if machine.isCloud {
      return cloudMachine(forMachineId: machine.id)?.online ?? false
    }
    return statusByMachineId[machine.id]?.isReachable ?? false
  }

  public func reconcileCloudSelection() {
    let selectedId = selectedMachineId
    if selectedId.hasPrefix(CodevisorMachine.cloudIdPrefix),
      machine(for: selectedId) != nil
    {
      applySelection(selectedId)
    }
    autoSelectPreferredMachineIfNeeded()
    ensureBackgroundConnections()
  }

  public func handleCloudAccountSignedOut() {
    guard selectedMachineId.hasPrefix(CodevisorMachine.cloudIdPrefix) else { return }
    registry.selectedMachineId = CodevisorMachine.local.id
    persist()
  }

  public func resetSelection() {
    registry = MachineRegistry()
    persist()
  }

  func persist() {
    do {
      try store.saveData(JSONEncoder().encode(registry.normalized()), forKey: key)
    } catch {
      Log.persistence.error(
        "Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }

  func connection(for machineId: String) -> MachineConnection {
    connections.connection(for: machineId)
  }

  func removeConnection(for machineId: String) {
    connections.remove(machineId)
  }

  func beginWaiting(for machineId: String, reason: ServerWaitingReason) {
    connection(for: machineId).beginWaiting(reason)
    requestGate.beginWaiting(for: machineId)
  }

  func markReady(for machineId: String) {
    connection(for: machineId).markReady()
    requestGate.markReady(for: machineId)
  }

  func markFailed(for machineId: String, message: String) {
    connection(for: machineId).markFailed(message)
    requestGate.markFailed(for: machineId, message: message)
  }

  public func retryMachine(_ machineId: String) async {
    guard machine(for: machineId) != nil else { return }
    await prepareMachine(machineId)
  }

  func schedulePreparationRetry(for machineId: String, delay override: Duration? = nil) {
    let connection = connection(for: machineId)
    connection.preparation.retryTask?.cancel()
    let delay = override ?? connection.preparation.nextRetryDelay(base: preparationRetryBaseDelay)
    let sleep = preparationSleep
    connection.preparation.retryTask = Task { [weak self] in
      try? await sleep(delay)
      guard let self, !Task.isCancelled else { return }
      connection.preparation.retryTask = nil
      guard self.machine(for: machineId) != nil,
        connection.preparation.task == nil,
        case .some(.failed) = connection.availability
      else { return }
      await self.prepareMachine(machineId)
    }
  }

  func scheduleRemoteRecovery(for machineId: String) {
    guard let machine = machine(for: machineId), !machine.isLocal else { return }
    schedulePreparationRetry(for: machineId)
  }

  public func cloudMachineBecameReachable(deviceId: String) {
    let machineId = CodevisorMachine.cloudIdPrefix + deviceId
    guard machine(for: machineId) != nil, let connection = connections.byId[machineId],
      connection.preparation.task == nil, case .failed = connection.availability
    else { return }
    Task { await self.prepareMachine(machineId) }
  }

  func pruneCloudTwinRecords(deviceId: String) {
    let twinId = CodevisorMachine.cloudIdPrefix + deviceId
    removeConnection(for: twinId)
    projectList.removeAllRecords(serverId: twinId)
  }

  func adoptLocalCloudIdentity(deviceId: String) {
    let connection = connection(for: CodevisorMachine.local.id)
    if var status = connection.status {
      status.cloudDeviceId = deviceId
      connection.status = status
    } else {
      connection.status = MachineStatus(
        isReachable: true,
        label: CodevisorMachine.local.name,
        cloudDeviceId: deviceId,
        serverId: CodevisorMachine.local.id
      )
    }
    pruneCloudTwinRecords(deviceId: deviceId)
  }

  public func pruneDeadCloudRecords() {
    guard let cloudProvider, cloudProvider.isCloudSignedIn, cloudProvider.isCloudRosterVerified else {
      return
    }
    let liveDeviceIds = Set(cloudProvider.cloudMachines.map(\.deviceId))
      .union(statusByMachineId.values.compactMap(\.cloudDeviceId))
    let storedServerIds = Set(
      projectList.projects.map(\.serverId) + projectList.sessions.map(\.serverId)
    ).union(navigationStore?.cachedMachineIds ?? [])
    for serverId in storedServerIds where serverId.hasPrefix(CodevisorMachine.cloudIdPrefix) {
      guard let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: serverId),
        !liveDeviceIds.contains(deviceId)
      else { continue }
      removeConnection(for: serverId)
      projectList.removeAllRecords(serverId: serverId)
    }
  }

  private func isCurrentBackgroundConnection(
    _ connection: MachineConnection,
    for machineId: String
  ) -> Bool {
    connections.byId[machineId] === connection
      && machine(for: machineId) != nil
      && !catalog.isCloudTwinOfConfiguredMachine(machineId)
  }

  public func connectMachine(_ machineId: String) async {
    guard machine(for: machineId) != nil else { return }
    guard !catalog.isCloudTwinOfConfiguredMachine(machineId) else { return }
    let connection = connection(for: machineId)
    guard connection.navigationSync.eventStreamTask == nil, !connection.preparation.backgroundConnectInFlight else {
      return
    }
    connection.preparation.backgroundConnectInFlight = true
    defer { connection.preparation.backgroundConnectInFlight = false }
    let client = client(for: machineId)
    await refreshStatus(for: machineId)
    guard isCurrentBackgroundConnection(connection, for: machineId) else { return }
    guard connection.status?.isReachable == true else {
      connection.navigationSyncState = .stale(connection.status?.label ?? "Unreachable")
      markFailed(for: machineId, message: connection.status?.label ?? "Unreachable")
      scheduleRemoteRecovery(for: machineId)
      return
    }
    markReady(for: machineId)
    await synchronizeNavigationState(serverId: machineId, client: client, presentation: .background)
    guard isCurrentBackgroundConnection(connection, for: machineId) else { return }
    onMachineConnected?(machineId)
  }

  public func ensureBackgroundConnections() {
    for machine in allMachines {
      guard connection(for: machine.id).isIdle else { continue }
      Task { await self.prepareMachine(machine.id) }
    }
  }
}
