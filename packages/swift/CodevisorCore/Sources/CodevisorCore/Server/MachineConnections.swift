import Foundation
import Observation

@MainActor
@Observable
final class MachineConnections {
  var byId: [String: MachineConnection] = [:]

  @ObservationIgnored private let reconnectNoticeDelay: Duration
  @ObservationIgnored private let awayNoticeDelay: Duration
  @ObservationIgnored private let noticeScheduler: SessionConnectionRecoveryScheduler
  @ObservationIgnored private let scheduler: SessionConnectionRecoveryScheduler

  init(
    reconnectNoticeDelay: Duration, awayNoticeDelay: Duration = .seconds(5),
    scheduler: SessionConnectionRecoveryScheduler, noticeScheduler: SessionConnectionRecoveryScheduler = .continuous
  ) {
    self.reconnectNoticeDelay = reconnectNoticeDelay
    self.awayNoticeDelay = awayNoticeDelay
    self.noticeScheduler = noticeScheduler
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
      reconnectNotice: makeNotice(delay: reconnectNoticeDelay, scheduler: scheduler),
      awayNotice: makeNotice(delay: awayNoticeDelay, scheduler: noticeScheduler))
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

  func isAway(_ machineId: String) -> Bool {
    byId[machineId]?.awayNotice.isVisible ?? true
  }

  func reportedIcon(for machineId: String) -> String? {
    byId[machineId]?.reportedIcon
  }

  private func makeNotice(
    delay: Duration, scheduler: SessionConnectionRecoveryScheduler
  ) -> DelayedConnectionNotice {
    DelayedConnectionNotice(delay: delay, now: scheduler.now, sleep: scheduler.sleep)
  }
}
