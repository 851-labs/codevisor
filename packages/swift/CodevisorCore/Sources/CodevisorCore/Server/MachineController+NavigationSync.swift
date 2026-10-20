import ACPKit
import Foundation

extension MachineController {
  static let shellSyncEventKinds: Set<String> = [
    "navigation.changed",
    "harness.lifecycle.updated",
    "harness.auth.updated",
    "harness.notice",
    "plugin.state.updated",
    "plugin.updated",
    "mcp.updated",
    "bot.updated",
    "update.changed",
    "sync.changed",
  ]

  public func startEventSync(for serverId: String, since initialCursor: Int = 0) {
    startEventSync(
      serverId: serverId,
      client: client(for: serverId),
      since: initialCursor
    )
  }

  func startEventSync(
    serverId: String,
    client: any CodevisorServerClienting,
    since initialCursor: Int
  ) {
    let connection = connection(for: serverId)
    connection.eventSyncTask?.cancel()
    connection.eventSyncTask = Task { [weak self] in
      do {
        for try await event in client.shellEventStream(
          since: max(0, initialCursor),
          handledKinds: Self.shellSyncEventKinds
        ) {
          guard let self, !Task.isCancelled else { return }
          await self.handleSyncEvent(
            event,
            serverId: serverId,
            client: client
          )
        }
        guard !Task.isCancelled else { return }
        connection.eventSyncTask = nil
        self?.navigationSynchronizationFailed(
          "The navigation event stream disconnected.", serverId: serverId, client: client
        )
      } catch {
        Log.machines.error(
          "Event sync for \(serverId, privacy: .public) failed; resubscribing: \(String(describing: error), privacy: .public)"
        )
        guard let self, !Task.isCancelled else { return }
        connection.eventSyncTask = nil
        self.navigationSynchronizationFailed(
          String(describing: error), serverId: serverId, client: client
        )
      }
    }
  }

  @concurrent
  nonisolated static func decodeNavigationDelta(_ payload: JSONValue) async throws -> ServerNavigationDelta {
    try JSONDecoder().decode(ServerNavigationDelta.self, from: JSONEncoder().encode(payload))
  }

  public func stopEventSync() {
    for connection in connectionsById.values {
      connection.manualNavigationRefresh?.cancel()
      connection.manualNavigationRefresh = nil
      connection.eventSyncTask?.cancel()
      connection.eventSyncTask = nil
      connection.pendingRefreshTask?.cancel()
      connection.pendingRefreshTask = nil
      connection.navigationRetryTask?.cancel()
      connection.navigationRetryTask = nil
      connection.navigationSyncTask?.cancel()
      connection.navigationSyncTask = nil
      connection.navigationSyncToken = nil
      connection.preparationRetryTask?.cancel()
      connection.preparationRetryTask = nil
    }
  }

  func stopEventSync(for machineId: String) {
    connectionsById[machineId]?.eventSyncTask?.cancel()
    connectionsById[machineId]?.eventSyncTask = nil
  }

  private func handleSyncEvent(
    _ event: ServerEventEnvelope,
    serverId: String,
    client: any CodevisorServerClienting
  ) async {
    DiagnosticsClient.shared.noteSyncEvent(
      machineIsLocal: serverId == CodevisorMachine.local.id,
      kind: event.kind
    )
    switch event.kind {
    case "navigation.changed":
      do {
        let delta = try await Self.decodeNavigationDelta(event.payload)
        guard let navigationStore else { return }
        guard await navigationStore.apply(delta, machineId: serverId) else {
          scheduleNavigationRefresh(serverId: serverId, client: client)
          return
        }
        let changed = Set(delta.sessions.compactMap { UUID(uuidString: $0.id) })
        for session in projectList.sessions where session.serverId == serverId && changed.contains(session.id) {
          onSessionStateChanged?(session, nil)
        }
      } catch {
        navigationSynchronizationFailed(String(describing: error), serverId: serverId, client: client)
      }
    case "harness.lifecycle.updated":
      onHarnessLifecycleChanged?(serverId)
    case "harness.auth.updated":
      onHarnessAuthChanged?(serverId)
    case "harness.notice":
      if let data = try? JSONEncoder().encode(event.payload),
        let notice = try? JSONDecoder().decode(ServerHarnessNotice.self, from: data)
      {
        onHarnessNotice?(notice)
      }
    case "plugin.state.updated":
      onPluginStateChanged?(serverId)
    case "mcp.updated":
      onMcpStateChanged?(serverId)
    case "bot.updated":
      onBotsChanged?(serverId)
    case "plugin.updated":
      onPluginUpdated?(serverId, event.subjectId)
    case "update.changed":
      if let data = try? JSONEncoder().encode(event.payload),
        let info = try? JSONDecoder().decode(ServerUpdateInfo.self, from: data)
      {
        connection(for: serverId).updateInfo = info
      }
    case "sync.changed":
      if let data = try? JSONEncoder().encode(event.payload),
        let document = try? JSONDecoder().decode(ServerSyncDocument.self, from: data)
      {
        onSyncChanged?(serverId, document)
      }
    default:
      break
    }
  }

  func scheduleNavigationRefresh(
    serverId: String,
    client: any CodevisorServerClienting
  ) {
    guard !Task.isCancelled else { return }
    let connection = connection(for: serverId)
    guard connection.pendingRefreshTask == nil else { return }
    let clock = navigationClock
    connection.pendingRefreshTask = Task { [weak self] in
      try? await clock.sleep(for: .milliseconds(300))
      guard let self, !Task.isCancelled else { return }
      connection.pendingRefreshTask = nil
      await self.synchronizeNavigationState(
        serverId: serverId,
        client: client,
        presentation: .background
      )
    }
  }

  public func refreshNavigationState(for serverId: String) async {
    await synchronizeNavigationState(
      serverId: serverId,
      client: client(for: serverId),
      presentation: .background
    )
  }

  func synchronizeNavigationState(
    serverId: String,
    client: any CodevisorServerClienting,
    presentation: NavigationSyncPresentation
  ) async {
    let connection = connection(for: serverId)
    if let existing = connection.navigationSyncTask {
      if presentation == .catchUp {
        connection.beginNavigationCatchUp()
      }
      await existing.value
      if connection.navigationSyncTask == nil,
        connection.navigationSyncState == .catchingUp
      {
        await synchronizeNavigationState(
          serverId: serverId,
          client: client,
          presentation: presentation
        )
      }
      return
    }

    connection.navigationSyncTask?.cancel()
    let token = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performNavigationSynchronization(
        serverId: serverId,
        client: client,
        presentation: presentation
      )
    }
    connection.navigationSyncToken = token
    connection.navigationSyncTask = task
    let clock = navigationClock
    let watchdog = Task {
      try? await clock.sleep(for: .seconds(30))
      guard !Task.isCancelled, connection.navigationSyncToken == token
      else { return }
      task.cancel()
      connection.navigationSyncToken = nil
      connection.navigationSyncTask = nil
      connection.navigationSyncState = .stale(
        "Timed out syncing with this machine."
      )
      scheduleNavigationRetry(serverId: serverId, client: client)
    }
    await task.value
    watchdog.cancel()
    if connection.navigationSyncToken == token {
      connection.navigationSyncToken = nil
      connection.navigationSyncTask = nil
    }
  }

  private func performNavigationSynchronization(
    serverId: String,
    client: any CodevisorServerClienting,
    presentation: NavigationSyncPresentation
  ) async {
    guard !Task.isCancelled else { return }
    if presentation == .catchUp {
      connection(for: serverId).beginNavigationCatchUp()
    }
    stopEventSync(for: serverId)

    let requestedAt = Date()
    let snapshot: ServerNavigationSnapshot
    do {
      snapshot = try await client.navigationSnapshot()
    } catch {
      navigationSynchronizationFailed(String(describing: error), serverId: serverId, client: client)
      return
    }
    guard !Task.isCancelled else { return }
    if let navigationStore {
      guard await navigationStore.replace(snapshot, machineId: serverId, requestedAt: requestedAt) else { return }
    }
    guard !Task.isCancelled else { return }
    startEventSync(serverId: serverId, client: client, since: snapshot.eventCursor)
    for session in projectList.sessions where session.serverId == serverId {
      onSessionStateChanged?(session, nil)
    }
    let connection = connection(for: serverId)
    connection.navigationSyncState = .current
    connection.navigationFailures = 0
    connection.navigationRetryTask?.cancel()
    connection.navigationRetryTask = nil
    navigationStore?.executor.resume(machineId: serverId)
  }
}
