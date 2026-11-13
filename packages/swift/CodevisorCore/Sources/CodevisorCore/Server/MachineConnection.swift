import Foundation
import Observation

@MainActor
@Observable
public final class MachineConnection {
  public let machineId: String

  public internal(set) var status: MachineStatus?
  public internal(set) var availability: ServerAvailability?
  public internal(set) var reportedIcon: String?
  public internal(set) var isWaitingForGit = false
  public private(set) var connectedSince: Date?

  let navigationSync = MachineNavigationSync()
  let serverUpdate = ServerUpdateState()
  let reconnector: MachineReconnector
  let reconnectNotice: DelayedConnectionNotice

  init(machineId: String, reconnector: MachineReconnector, reconnectNotice: DelayedConnectionNotice) {
    self.machineId = machineId
    self.reconnector = reconnector
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

  public internal(set) var updateRun: ServerUpdateRunState? {
    get { serverUpdate.updateRun }
    set { serverUpdate.updateRun = newValue }
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

  public var updateActivity: ServerUpdateActivity? {
    serverUpdate.activity
  }

  var isIdle: Bool {
    navigationSync.eventStreamTask == nil && !reconnector.isActive
  }

  func beginWaiting(_ reason: ServerWaitingReason) {
    navigationSync.stopSyncing()
    availability = .waiting(reason)
    reconnectNotice.update(isActive: true)
    navigationSync.beginCatchUp()
  }

  func markReady() {
    if availability != .ready { connectedSince = Date() }
    availability = .ready
    reconnectNotice.update(isActive: false)
  }

  func markFailed(_ message: String) {
    availability = .failed(message)
    reconnectNotice.update(isActive: true)
    navigationSyncState = .stale(message)
  }

  func cancelSyncWork() {
    navigationSync.cancelAll()
    reconnector.stop()
  }
}
