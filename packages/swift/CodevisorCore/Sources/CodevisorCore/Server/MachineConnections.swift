import Foundation
import Observation

@MainActor
@Observable
final class MachineConnections {
  var byId: [String: MachineConnection] = [:]

  @ObservationIgnored private let reconnectNoticeDelay: Duration
  @ObservationIgnored private let scheduler: SessionConnectionRecoveryScheduler

  init(reconnectNoticeDelay: Duration, scheduler: SessionConnectionRecoveryScheduler) {
    self.reconnectNoticeDelay = reconnectNoticeDelay
    self.scheduler = scheduler
  }

  var statusById: [String: MachineStatus] {
    byId.compactMapValues(\.status)
  }

  var availabilityById: [String: ServerAvailability] {
    byId.compactMapValues(\.availability)
  }

  var navigationSyncStateById: [String: NavigationSyncState] {
    byId.compactMapValues(\.navigationSyncState)
  }

  func connection(for machineId: String) -> MachineConnection {
    if let existing = byId[machineId] { return existing }
    let connection = MachineConnection(
      machineId: machineId, reconnector: MachineReconnector(scheduler: scheduler),
      reconnectNotice: makeReconnectNotice())
    byId[machineId] = connection
    return connection
  }

  func remove(_ machineId: String) {
    byId[machineId]?.cancelSyncWork()
    byId[machineId] = nil
  }

  func availability(for machineId: String) -> ServerAvailability {
    byId[machineId]?.availability ?? .waiting(.connecting)
  }

  func isWaitingForGit(on machineId: String) -> Bool {
    byId[machineId]?.isWaitingForGit ?? false
  }

  func updateActivity(for machineId: String) -> ServerUpdateActivity? {
    byId[machineId]?.updateActivity
  }

  func updatePauseSubject(machineId: String, sessionId: UUID?, harnessId: String?) -> ServerUpdatePauseSubject? {
    byId[machineId]?.restartDrain?.pauseSubject(sessionId: sessionId, harnessId: harnessId)
  }

  func showsReconnectNotice(for machineId: String) -> Bool {
    byId[machineId]?.reconnectNotice.isVisible ?? true
  }

  func reportedIcon(for machineId: String) -> String? {
    byId[machineId]?.reportedIcon
  }

  private func makeReconnectNotice() -> DelayedConnectionNotice {
    DelayedConnectionNotice(
      delay: reconnectNoticeDelay, now: scheduler.now, sleep: scheduler.sleep)
  }
}
