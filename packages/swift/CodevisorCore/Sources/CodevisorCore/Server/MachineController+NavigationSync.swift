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
    "restart.drain.updated",
    "sync.changed",
  ]

  private static let navigationRefreshDelay: Duration = .milliseconds(300)
  private static let navigationSyncTimeout: Duration = .seconds(30)

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
      await connection.loadRestartDrain(from: client)
      do {
        for try await event in client.shellEventStream(
          since: max(0, initialCursor),
          handledKinds: Self.shellSyncEventKinds
        ) {
          guard let self, !Task.isCancelled else { return }
          await self.handleSyncEvent(event, serverId: serverId, client: client)
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

  public func stopEventSync() {
    for connection in connectionsById.values {
      connection.cancelSyncWork()
    }
  }

  func stopEventSync(for machineId: String) {
    connectionsById[machineId]?.eventSyncTask?.cancel()
    connectionsById[machineId]?.eventSyncTask = nil
  }

  private func handleSyncEvent(
    _ event: ServerEventEnvelope, serverId: String, client: any CodevisorServerClienting
  ) async {
    DiagnosticsClient.shared.noteSyncEvent(
      machineIsLocal: serverId == CodevisorMachine.local.id,
      kind: event.kind
    )
    switch event.kind {
    case "navigation.changed":
      await applyNavigationChange(event.payload, serverId: serverId, client: client)
    case "harness.lifecycle.updated":
      onHarnessLifecycleChanged?(serverId)
    case "harness.auth.updated":
      onHarnessAuthChanged?(serverId)
    case "harness.notice":
      if let notice = ShellSyncPayload.decoded(ServerHarnessNotice.self, from: event.payload) {
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
      if let info = ShellSyncPayload.decoded(ServerUpdateInfo.self, from: event.payload) {
        connection(for: serverId).updateInfo = info
      }
    case "restart.drain.updated":
      if let drain = ShellSyncPayload.decoded(ServerRestartDrainState.self, from: event.payload) {
        connection(for: serverId).restartDrain = drain
      }
    case "sync.changed":
      if let document = ShellSyncPayload.decoded(ServerSyncDocument.self, from: event.payload) {
        onSyncChanged?(serverId, document)
      }
    default:
      break
    }
  }

  private func applyNavigationChange(
    _ payload: JSONValue, serverId: String, client: any CodevisorServerClienting
  ) async {
    let delta: ServerNavigationDelta
    do {
      delta = try await ShellSyncPayload.navigationDelta(payload)
    } catch {
      navigationSynchronizationFailed(String(describing: error), serverId: serverId, client: client)
      return
    }
    guard let navigationStore else { return }
    guard await navigationStore.apply(delta, machineId: serverId) else {
      scheduleNavigationRefresh(serverId: serverId, client: client)
      return
    }

    let changed = Set(delta.sessions.compactMap { UUID(uuidString: $0.id) })
    notifySessionStatesChanged(serverId: serverId) { changed.contains($0.id) }
  }

  func scheduleNavigationRefresh(serverId: String, client: any CodevisorServerClienting) {
    guard !Task.isCancelled else { return }
    let connection = connection(for: serverId)
    guard connection.pendingRefreshTask == nil else { return }

    let clock = navigationClock
    connection.pendingRefreshTask = Task { [weak self] in
      try? await clock.sleep(for: Self.navigationRefreshDelay)
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
      await joinNavigationSync(
        existing, on: connection, serverId: serverId, client: client, presentation: presentation)
      return
    }

    await runNavigationSync(on: connection, serverId: serverId, client: client, presentation: presentation)
  }

  private func joinNavigationSync(
    _ existing: Task<Void, Never>, on connection: MachineConnection,
    serverId: String, client: any CodevisorServerClienting, presentation: NavigationSyncPresentation
  ) async {
    if presentation == .catchUp {
      connection.beginNavigationCatchUp()
    }
    await existing.value
    guard connection.isWaitingForCatchUp else { return }

    await synchronizeNavigationState(serverId: serverId, client: client, presentation: presentation)
  }

  private func runNavigationSync(
    on connection: MachineConnection,
    serverId: String, client: any CodevisorServerClienting, presentation: NavigationSyncPresentation
  ) async {
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performNavigationSynchronization(serverId: serverId, client: client, presentation: presentation)
    }
    let token = connection.beginNavigationSync(task)
    let watchdog = startNavigationSyncWatchdog(
      for: task, token: token, on: connection, serverId: serverId, client: client)

    await task.value
    watchdog.cancel()
    connection.finishNavigationSync(token)
  }

  private func startNavigationSyncWatchdog(
    for task: Task<Void, Never>, token: UUID, on connection: MachineConnection,
    serverId: String, client: any CodevisorServerClienting
  ) -> Task<Void, Never> {
    let clock = navigationClock
    return Task {
      try? await clock.sleep(for: Self.navigationSyncTimeout)
      guard !Task.isCancelled, connection.isRunningNavigationSync(token) else { return }

      task.cancel()
      connection.endNavigationSync()
      connection.navigationSyncState = .stale("Timed out syncing with this machine.")
      scheduleNavigationRetry(serverId: serverId, client: client)
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
    guard let snapshot = await navigationSnapshot(serverId: serverId, client: client) else { return }
    guard !Task.isCancelled else { return }
    if let navigationStore {
      guard await navigationStore.replace(snapshot, machineId: serverId, requestedAt: requestedAt) else { return }
    }
    guard !Task.isCancelled else { return }

    startEventSync(serverId: serverId, client: client, since: snapshot.eventCursor)
    notifySessionStatesChanged(serverId: serverId)
    markNavigationCurrent(serverId: serverId)
  }

  private func navigationSnapshot(
    serverId: String, client: any CodevisorServerClienting
  ) async -> ServerNavigationSnapshot? {
    do {
      return try await client.navigationSnapshot()
    } catch {
      navigationSynchronizationFailed(String(describing: error), serverId: serverId, client: client)
      return nil
    }
  }

  private func notifySessionStatesChanged(
    serverId: String,
    where isIncluded: (ChatSession) -> Bool = { _ in true }
  ) {
    for session in projectList.sessions where session.serverId == serverId && isIncluded(session) {
      onSessionStateChanged?(session, nil)
    }
  }

  private func markNavigationCurrent(serverId: String) {
    connection(for: serverId).markNavigationCurrent()
    navigationStore?.executor.resume(machineId: serverId)
  }
}
