import Foundation
import Observation

@MainActor
@Observable
public final class MachineConnection {
  public let machineId: String

  public internal(set) var status: MachineStatus?
  public internal(set) var availability: ServerAvailability?
  public internal(set) var reportedIcon: String?

  let navigationSync = MachineNavigationSync()
  let serverUpdate = ServerUpdateState()
  let preparation = MachinePreparation()
  let reconnectNotice: DelayedConnectionNotice

  init(machineId: String, reconnectNotice: DelayedConnectionNotice) {
    self.machineId = machineId
    self.reconnectNotice = reconnectNotice
  }

  public internal(set) var navigationSyncState: NavigationSyncState? {
    get { navigationSync.state }
    set { navigationSync.state = newValue }
  }

  public internal(set) var updateInfo: ServerUpdateInfo? {
    get { serverUpdate.info }
    set { serverUpdate.info = newValue }
  }

  public internal(set) var restartDrain: ServerRestartDrainState? {
    get { serverUpdate.restartDrain }
    set { serverUpdate.restartDrain = newValue }
  }

  public internal(set) var updatePhase: ServerUpdatePhase {
    get { serverUpdate.phase }
    set { serverUpdate.phase = newValue }
  }

  public internal(set) var updateStatusMessage: String? {
    get { serverUpdate.statusMessage }
    set { serverUpdate.statusMessage = newValue }
  }

  public internal(set) var updateProgress: Double? {
    get { serverUpdate.progress }
    set { serverUpdate.progress = newValue }
  }

  public internal(set) var dataUpgradeProgress: ServerMigrationProgress? {
    get { serverUpdate.dataUpgradeProgress }
    set { serverUpdate.dataUpgradeProgress = newValue }
  }

  var isIdle: Bool {
    navigationSync.eventStreamTask == nil
      && preparation.task == nil
      && !preparation.backgroundConnectInFlight
  }

  func beginWaiting(_ reason: ServerWaitingReason) {
    navigationSync.stopSyncing()
    preparation.cancelRetry()
    availability = .waiting(reason)
    reconnectNotice.update(isActive: true)
    navigationSync.beginCatchUp()
  }

  func markReady() {
    availability = .ready
    reconnectNotice.update(isActive: false)
    preparation.resetRetries()
  }

  func markFailed(_ message: String) {
    availability = .failed(message)
    reconnectNotice.update(isActive: true)
    navigationSyncState = .stale(message)
  }

  func cancelSyncWork() {
    navigationSync.cancelAll()
    preparation.cancelRetry()
  }

  func cancelAllWork() {
    navigationSync.manualRefresh?.cancel()
    navigationSync.eventStreamTask?.cancel()
    preparation.task?.cancel()
    navigationSync.task?.cancel()
    navigationSync.pendingRefreshTask?.cancel()
    navigationSync.retryTask?.cancel()
    preparation.retryTask?.cancel()
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
    connectionsById[machineId]?.cancelAllWork()
    connectionsById[machineId] = nil
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
    guard machine(for: machineId) != nil, let connection = connectionsById[machineId],
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
    local.icon = icon(chosen: presence?.icon, reportedBy: local.id)
    return [local]
  }

  public func icon(for cloud: CloudMachine) -> MachineIcon {
    let machineId =
      cloud.deviceId == localCloudMachine?.deviceId
      ? CodevisorMachine.local.id : CodevisorMachine.cloudIdPrefix + cloud.deviceId
    return icon(chosen: cloud.icon, reportedBy: machineId)
  }

  func icon(chosen: String?, reportedBy machineId: String) -> MachineIcon {
    MachineIcon(known: chosen) ?? MachineIcon(resolving: connectionsById[machineId]?.reportedIcon)
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

  public func isPausedForUpdate(machineId: String, sessionId: UUID?) -> Bool {
    connectionsById[machineId]?.restartDrain?.pausesSending(sessionId: sessionId) ?? false
  }

  public func showsReconnectNotice(for machineId: String) -> Bool {
    connectionsById[machineId]?.reconnectNotice.isVisible ?? true
  }

  public var navigationSyncStateByMachineId: [String: NavigationSyncState] {
    connectionsById.compactMapValues(\.navigationSyncState)
  }
}
