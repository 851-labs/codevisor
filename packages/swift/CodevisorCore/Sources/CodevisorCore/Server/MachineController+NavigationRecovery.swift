import Foundation

extension MachineController {
  func navigationSynchronizationFailed(
    _ message: String, serverId: String, client: any CodevisorServerClienting
  ) {
    guard !Task.isCancelled else { return }
    connection(for: serverId).navigationSyncState = .stale(message)
    scheduleNavigationRetry(serverId: serverId, client: client)
  }

  /// One retry per machine, with bounded backoff. A healthy socket does not
  /// imply healthy list requests, so snapshot recovery has its own lifetime.
  func scheduleNavigationRetry(serverId: String, client: any CodevisorServerClienting) {
    let connection = connection(for: serverId)
    guard connection.navigationRetryTask == nil else { return }
    connection.navigationFailures += 1
    let delay = Duration.seconds(min(60, 1 << min(connection.navigationFailures, 6)))
    let clock = navigationClock
    connection.navigationRetryTask = Task { [weak self] in
      try? await clock.sleep(for: delay)
      guard let self, !Task.isCancelled,
        self.connectionsById[serverId] === connection
      else { return }
      connection.navigationRetryTask = nil
      await self.synchronizeNavigationState(
        serverId: serverId, client: client, presentation: .background
      )
    }
  }
}
