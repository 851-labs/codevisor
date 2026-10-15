import Foundation
import Observation

@MainActor
@Observable
public final class MachineConnection {
  public let machineId: String

  public internal(set) var status: MachineStatus?
  public internal(set) var updateInfo: ServerUpdateInfo?
  public internal(set) var availability: ServerAvailability?
  public internal(set) var navigationSyncState: NavigationSyncState?
  public internal(set) var updatePhase: ServerUpdatePhase = .idle
  public internal(set) var updateStatusMessage: String?
  public internal(set) var updateProgress: Double?
  public internal(set) var dataUpgradeProgress: ServerMigrationProgress?

  @ObservationIgnored var eventSyncTask: Task<Void, Never>?
  @ObservationIgnored var backgroundConnectInFlight = false
  @ObservationIgnored var preparationTask: Task<Void, Never>?
  @ObservationIgnored var navigationSyncToken: UUID?
  @ObservationIgnored var navigationSyncTask: Task<Void, Never>?

  @ObservationIgnored var manualNavigationRefresh: MachineNavigationRefresh?
  @ObservationIgnored var pendingRefreshTask: Task<Void, Never>?
  @ObservationIgnored var navigationRetryTask: Task<Void, Never>?
  @ObservationIgnored var navigationFailures = 0
  @ObservationIgnored var preparationRetryTask: Task<Void, Never>?
  @ObservationIgnored var preparationFailures = 0

  let reconnectNotice: DelayedConnectionNotice

  init(machineId: String, reconnectNotice: DelayedConnectionNotice) {
    self.machineId = machineId
    self.reconnectNotice = reconnectNotice
  }

  func beginNavigationCatchUp() {
    if navigationSyncState == nil || navigationSyncState == .cached {
      navigationSyncState = .catchingUp
    }
  }
}

extension MachineController {
  var persistenceStore: any PersistenceStore { store }

  func connection(for machineId: String) -> MachineConnection {
    if let existing = connectionsById[machineId] { return existing }
    let connection = MachineConnection(
      machineId: machineId,
      reconnectNotice: DelayedConnectionNotice(
        delay: reconnectNoticeDelay, now: reconnectNoticeScheduler.now, sleep: reconnectNoticeScheduler.sleep))
    connectionsById[machineId] = connection
    return connection
  }

  func removeConnection(for machineId: String) {
    connectionsById[machineId]?.manualNavigationRefresh?.cancel()
    connectionsById[machineId]?.eventSyncTask?.cancel()
    connectionsById[machineId]?.preparationTask?.cancel()
    connectionsById[machineId]?.navigationSyncTask?.cancel()
    connectionsById[machineId]?.pendingRefreshTask?.cancel()
    connectionsById[machineId]?.navigationRetryTask?.cancel()
    connectionsById[machineId]?.preparationRetryTask?.cancel()
    connectionsById[machineId] = nil
  }

  func beginWaiting(for machineId: String, reason: ServerWaitingReason) {
    let connection = connection(for: machineId)
    connection.navigationSyncTask?.cancel()
    connection.navigationSyncToken = nil
    connection.navigationSyncTask = nil
    connection.pendingRefreshTask?.cancel()
    connection.pendingRefreshTask = nil
    connection.navigationRetryTask?.cancel()
    connection.navigationRetryTask = nil
    stopEventSync(for: machineId)
    connection.preparationRetryTask?.cancel()
    connection.preparationRetryTask = nil
    connection.availability = .waiting(reason)
    connection.reconnectNotice.update(isActive: true)
    connection.beginNavigationCatchUp()
    requestGate.beginWaiting(for: machineId)
  }

  func markReady(for machineId: String) {
    let connection = connection(for: machineId)
    connection.availability = .ready
    connection.reconnectNotice.update(isActive: false)
    connection.preparationRetryTask?.cancel()
    connection.preparationRetryTask = nil
    connection.preparationFailures = 0
    requestGate.markReady(for: machineId)
  }

  func markFailed(for machineId: String, message: String) {
    let connection = connection(for: machineId)
    connection.availability = .failed(message)
    connection.reconnectNotice.update(isActive: true)
    connection.navigationSyncState = .stale(message)
    requestGate.markFailed(for: machineId, message: message)
  }

  public func retryMachine(_ machineId: String) async {
    guard machine(for: machineId) != nil else { return }
    await prepareMachine(machineId)
  }

  func schedulePreparationRetry(for machineId: String, delay override: Duration? = nil) {
    let connection = connection(for: machineId)
    connection.preparationRetryTask?.cancel()
    let delay: Duration
    if let override {
      delay = override
    } else {
      connection.preparationFailures += 1
      delay = preparationRetryBaseDelay * min(60, 1 << min(connection.preparationFailures, 6))
    }
    let sleep = preparationSleep
    connection.preparationRetryTask = Task { [weak self] in
      try? await sleep(delay)
      guard let self, !Task.isCancelled else { return }
      connection.preparationRetryTask = nil
      guard self.machine(for: machineId) != nil,
        connection.preparationTask == nil,
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
    guard machine(for: machineId) != nil, let connection = connectionsById[machineId],
      connection.preparationTask == nil, case .failed = connection.availability
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

  func isCloudTwinOfConfiguredMachine(_ machineId: String) -> Bool {
    guard let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: machineId) else {
      return false
    }
    let configuredIds = Set(machines.map(\.id))
    return statusByMachineId.contains { key, status in
      configuredIds.contains(key) && status.cloudDeviceId == deviceId
    }
  }

  private func isCurrentBackgroundConnection(
    _ connection: MachineConnection,
    for machineId: String
  ) -> Bool {
    connectionsById[machineId] === connection
      && machine(for: machineId) != nil
      && !isCloudTwinOfConfiguredMachine(machineId)
  }

  public func connectMachine(_ machineId: String) async {
    guard machine(for: machineId) != nil else { return }
    guard !isCloudTwinOfConfiguredMachine(machineId) else { return }
    let connection = connection(for: machineId)
    guard connection.eventSyncTask == nil, !connection.backgroundConnectInFlight else {
      return
    }
    connection.backgroundConnectInFlight = true
    defer { connection.backgroundConnectInFlight = false }
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
      let connection = connection(for: machine.id)
      guard connection.eventSyncTask == nil,
        connection.preparationTask == nil,
        !connection.backgroundConnectInFlight
      else {
        continue
      }
      Task { await self.prepareMachine(machine.id) }
    }
  }

  public var selectedMachineId: String {
    registry.selectedMachineId
  }

  public var selectedMachine: CodevisorMachine {
    machine(for: registry.selectedMachineId) ?? allMachines.first ?? CodevisorMachine.local
  }

  public var machines: [CodevisorMachine] {
    guard includesLocalMachine else { return [] }
    var local = CodevisorMachine.local
    let presence = localCloudMachine
    if let presence { local.name = presence.name }
    local.icon = MachineIcon(resolving: presence?.icon ?? statusByMachineId[local.id]?.icon)
    return [local]
  }

  public var localCloudMachine: CloudMachine? {
    guard let deviceId = statusByMachineId[CodevisorMachine.local.id]?.cloudDeviceId,
      let cloudProvider, cloudProvider.isCloudSignedIn
    else { return nil }
    return cloudProvider.cloudMachines.first { $0.deviceId == deviceId }
  }

  public func machine(for id: String) -> CodevisorMachine? {
    allMachines.first { $0.id == id }
  }

  public func canonicalComposerMachineId(for id: String) -> String? {
    if machine(for: id) != nil, !isCloudTwinOfConfiguredMachine(id) {
      return id
    }
    guard let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: id) else {
      return nil
    }
    return machines.first {
      statusByMachineId[$0.id]?.cloudDeviceId == deviceId
    }?.id
  }

  public func fleetMachineName(for serverId: String) -> String? {
    machine(for: serverId)?.name
  }

  public func machineId(forSyncKey key: String) -> String? {
    statusByMachineId.first { $0.value.serverId == key }?.key
  }

  public func syncKey(forMachineId id: String) -> String? {
    statusByMachineId[id]?.serverId
  }

  public func fleetName(forSyncKey key: String) -> String {
    guard let machineId = machineId(forSyncKey: key) else { return key }
    return fleetMachineName(for: machineId) ?? key
  }

  public func cloudMachine(forMachineId id: String) -> CloudMachine? {
    guard let deviceId = CodevisorMachine.cloudDeviceId(forMachineId: id),
      let cloudProvider, cloudProvider.isCloudSignedIn
    else { return nil }
    return cloudProvider.cloudMachines.first { $0.deviceId == deviceId }
  }

  public var statusByMachineId: [String: MachineStatus] {
    connectionsById.compactMapValues(\.status)
  }

  public var availabilityByMachineId: [String: ServerAvailability] {
    connectionsById.compactMapValues(\.availability)
  }

  public func availability(for machineId: String) -> ServerAvailability {
    connectionsById[machineId]?.availability ?? .waiting(.connecting)
  }

  public func showsReconnectNotice(for machineId: String) -> Bool {
    connectionsById[machineId]?.reconnectNotice.isVisible ?? true
  }

  public var navigationSyncStateByMachineId: [String: NavigationSyncState] {
    connectionsById.compactMapValues(\.navigationSyncState)
  }
}
