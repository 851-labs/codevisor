import Foundation

extension MachineController {
  func navigationConnectionLost(_ message: String, serverId: String) {
    guard !Task.isCancelled else { return }

    connection(for: serverId).navigationSyncState = .stale(message)
    connectionLost(machineId: serverId)
  }

  func navigationNeedsSnapshot(_ message: String, serverId: String, client: any CodevisorServerClienting) {
    guard !Task.isCancelled else { return }

    connection(for: serverId).navigationSyncState = .stale(message)
    scheduleNavigationRefresh(serverId: serverId, client: client)
  }

  func navigationStreamFailed(_ error: any Error, serverId: String, client: any CodevisorServerClienting) {
    guard ServerConnectionLoss.isConnectionLoss(error) else {
      return navigationNeedsSnapshot(String(describing: error), serverId: serverId, client: client)
    }
    navigationConnectionLost(String(describing: error), serverId: serverId)
  }

  func navigationSnapshotFailed(_ error: any Error, serverId: String) {
    guard ServerConnectionLoss.isConnectionLoss(error) else {
      connection(for: serverId).navigationSyncState = .stale(String(describing: error))
      return
    }
    navigationConnectionLost(String(describing: error), serverId: serverId)
  }
}
