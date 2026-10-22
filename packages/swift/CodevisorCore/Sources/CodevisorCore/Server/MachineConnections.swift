import Foundation
import Observation

@MainActor
@Observable
final class MachineConnections {
  var byId: [String: MachineConnection] = [:]

  @ObservationIgnored private let reconnectNoticeDelay: Duration
  @ObservationIgnored private let reconnectNoticeScheduler: SessionConnectionRecoveryScheduler

  init(reconnectNoticeDelay: Duration, reconnectNoticeScheduler: SessionConnectionRecoveryScheduler) {
    self.reconnectNoticeDelay = reconnectNoticeDelay
    self.reconnectNoticeScheduler = reconnectNoticeScheduler
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
    let connection = MachineConnection(machineId: machineId, reconnectNotice: makeReconnectNotice())
    byId[machineId] = connection
    return connection
  }

  func remove(_ machineId: String) {
    byId[machineId]?.cancelAllWork()
    byId[machineId] = nil
  }

  func availability(for machineId: String) -> ServerAvailability {
    byId[machineId]?.availability ?? .waiting(.connecting)
  }

  func isPausedForUpdate(machineId: String, sessionId: UUID?) -> Bool {
    byId[machineId]?.restartDrain?.pausesSending(sessionId: sessionId) ?? false
  }

  func showsReconnectNotice(for machineId: String) -> Bool {
    byId[machineId]?.reconnectNotice.isVisible ?? true
  }

  func reportedIcon(for machineId: String) -> String? {
    byId[machineId]?.reportedIcon
  }

  private func makeReconnectNotice() -> DelayedConnectionNotice {
    DelayedConnectionNotice(
      delay: reconnectNoticeDelay, now: reconnectNoticeScheduler.now, sleep: reconnectNoticeScheduler.sleep)
  }
}
