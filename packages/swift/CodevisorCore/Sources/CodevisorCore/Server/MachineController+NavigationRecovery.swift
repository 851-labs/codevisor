import Foundation

extension MachineController {
  func navigationSynchronizationFailed(
    _ message: String, serverId: String, client: any CodevisorServerClienting
  ) {
    guard !Task.isCancelled else { return }
    connection(for: serverId).navigationSyncState = .stale(message)
    scheduleNavigationRetry(serverId: serverId, client: client)
  }

  func scheduleNavigationRetry(serverId: String, client: any CodevisorServerClienting) {
    let connection = connection(for: serverId)
    guard connection.navigationSync.retryTask == nil else { return }
    let delay = connection.navigationSync.nextRetryDelay()
    let clock = navigationClock
    connection.navigationSync.retryTask = Task { [weak self] in
      try? await clock.sleep(for: delay)
      guard let self, !Task.isCancelled,
        self.connectionsById[serverId] === connection
      else { return }
      connection.navigationSync.retryTask = nil
      await self.synchronizeNavigationState(
        serverId: serverId, client: client, presentation: .background
      )
    }
  }
}
