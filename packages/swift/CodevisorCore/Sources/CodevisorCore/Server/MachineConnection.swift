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
