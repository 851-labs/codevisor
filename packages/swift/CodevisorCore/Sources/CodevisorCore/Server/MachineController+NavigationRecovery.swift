import Foundation

extension MachineController {
  /// A consumed event must not lose its change when its follow-up HTTP request
  /// fails. Keep the stream alive and retry the complete navigation snapshot.
  func refreshWorkspacesAfterEvent(serverId: String, client: any CodevisorServerClienting) async {
    guard let workspaceSync else { return }
    let result = await workspaceSync.refreshFromServer(serverId: serverId, client: client)
    guard !Task.isCancelled else { return }
    switch result {
    case .committed:
      break
    case .superseded:
      scheduleNavigationRefresh(serverId: serverId, client: client)
    case let .failed(message):
      navigationSynchronizationFailed(message, serverId: serverId, client: client)
    }
  }

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
    let sleep = navigationSleep
    connection.navigationRetryTask = Task { [weak self] in
      try? await sleep(delay)
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
