import Foundation

extension MachineController {
  /// The only event kinds `handleSyncEvent` acts on. Everything else on the
  /// global socket — most of it per-token `session.output` chunks from every
  /// streaming session — is filtered inside the client's stream task so it
  /// never pays a main-actor hop just to hit the `default:` case below.
  static let shellSyncEventKinds: Set<String> = [
    "navigation.changed",
    "harness.lifecycle.updated",
    "harness.auth.updated",
    "plugin.state.updated",
    "plugin.updated",
    "mcp.updated",
    "update.changed",
    "sync.changed",
  ]

  /// Follows one explicit server's event stream so projects and sessions
  /// stay in sync without consulting composer or navigation defaults.
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

  /// Stops every machine's event stream (app teardown and tests).
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

  /// Stops one machine's event stream, leaving every other machine's alive.
  func stopEventSync(for machineId: String) {
    connectionsById[machineId]?.eventSyncTask?.cancel()
    connectionsById[machineId]?.eventSyncTask = nil
  }

  /// Re-homes one machine's live shell stream after its route flips.
  func rerouteStreams(for machineId: String) {
    stopEventSync(for: machineId)
    let client = client(for: machineId)
    // The sync path owns the blocking state; writing it here too raced
    // an in-flight sync's terminal write and could strand the spinner.
    Task { [weak self] in
      await self?.synchronizeNavigationState(
        serverId: machineId,
        client: client,
        presentation: .catchUp
      )
    }
  }

  private func handleSyncEvent(
    _ event: ServerEventEnvelope,
    serverId: String,
    client: any CodevisorServerClienting
  ) async {
    // Events from every machine apply: all row stores and refreshes are
    // explicitly serverId-keyed.
    DiagnosticsClient.shared.noteSyncEvent(
      machineIsLocal: serverId == CodevisorMachine.local.id,
      kind: event.kind
    )
    switch event.kind {
    case "navigation.changed":
      do {
        let delta = try JSONDecoder().decode(ServerNavigationDelta.self, from: JSONEncoder().encode(event.payload))
        let connection = connection(for: serverId)
        guard let current = connection.navigationSnapshot else { throw CodevisorServerClientError.invalidResponse }
        guard delta.eventCursor > current.eventCursor else { return }
        let snapshot = delta.applying(to: current)
        let prepared = await ServerNavigationSnapshotBuilder.build(
          projects: snapshot.projects, sessions: snapshot.sessions, serverId: serverId)
        guard !Task.isCancelled, connection.navigationSnapshot?.eventCursor == current.eventCursor else { return }
        projectList.commitSnapshot(prepared, serverId: serverId, origin: .liveEvent)
        workspaceSync?.applyNavigationDelta(delta, previous: current, snapshot: snapshot, serverId: serverId)
        connection.navigationSnapshot = snapshot
        let changed = Set(delta.sessions.map { $0.id.lowercased() })
        for session in projectList.sessions
        where session.serverId == serverId && changed.contains(session.id.uuidString.lowercased()) {
          onSessionStateChanged?(session, nil)
        }
      } catch {
        navigationSynchronizationFailed(String(describing: error), serverId: serverId, client: client)
      }
    case "harness.lifecycle.updated":
      // Update detection / install progress changed a harness — bump
      // the catalog revision so mounted pickers and settings refetch.
      onHarnessLifecycleChanged?(serverId)
    case "harness.auth.updated":
      // A sign-in probe finished or an account changed state (a native
      // login adopted during onboarding, a Terminal sign-out, an expired
      // token) — bump the catalog revision so onboarding, settings, and
      // pickers refetch instead of sitting on "Checking sign-in…".
      onHarnessAuthChanged?(serverId)
    case "plugin.state.updated":
      // A plugin started, stopped, crashed, or the installed list
      // changed — bump the revision so state chips and cards refetch.
      onPluginStateChanged?(serverId)
    case "mcp.updated":
      // A managed MCP server's state moved on this machine — bump the
      // revision so the MCP settings pane refetches instead of polling.
      onMcpStateChanged?(serverId)
    case "plugin.updated":
      // The plugin's code/install changed (restart, re-import, link) —
      // open panes reload. Deliberately NOT driven off
      // plugin.state.updated: routine runtime transitions must not
      // reload the plugin's pane content.
      onPluginUpdated?(serverId, event.subjectId)
    case "update.changed":
      // The machine's server release state changed (a new release, a
      // converged install, or an unattended-apply report) — adopt the
      // authoritative payload without waiting for the next poll.
      if let data = try? JSONEncoder().encode(event.payload),
        let info = try? JSONDecoder().decode(ServerUpdateInfo.self, from: data)
      {
        connection(for: serverId).updateInfo = info
      }
    case "sync.changed":
      // A machine's config replica changed: hand the changed entries
      // to ConfigSync, which adopts and re-gossips them.
      if let data = try? JSONEncoder().encode(event.payload),
        let document = try? JSONDecoder().decode(ServerSyncDocument.self, from: data)
      {
        onSyncChanged?(serverId, document)
      }
    default:
      // Prompt/queue/error events are handled by the session transports.
      break
    }
  }

  /// Coalesces bursts of events (including the initial replay) into a single
  /// refresh from the server.
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

  /// Refreshes one explicit machine's authoritative navigation snapshot.
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
      // A superseded snapshot can finish without a terminal state. A
      // cold catch-up must not stay displayed with no task to clear it.
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
    // The spinner must never outlive the wait: a catch-up wedged on a
    // half-open transport hangs rather than fails, so a deadline cancels
    // it and demotes to stale — cached rows plus retry, not a spinner.
    let clock = navigationClock
    let watchdog = Task {
      // A captured async sleep closure corrupts the task allocator in the
      // native SwiftPM test runner. Keep the timer on Clock's typed API.
      try? await clock.sleep(for: .seconds(30))
      guard !Task.isCancelled, connection.navigationSyncToken == token
      else { return }
      task.cancel()
      // A transport that ignores cancellation must not keep owning sync and
      // force every retry to join the same wedged request.
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

  /// Installs state and its cursor from one database snapshot before subscribing.
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

    var snapshot: ServerNavigationSnapshot
    do {
      snapshot = try await client.navigationSnapshot()
    } catch {
      navigationSynchronizationFailed(String(describing: error), serverId: serverId, client: client)
      return
    }
    guard !Task.isCancelled else { return }
    let initialCursor = snapshot.eventCursor
    let prepared = await ServerNavigationSnapshotBuilder.build(
      projects: snapshot.projects, sessions: snapshot.sessions, serverId: serverId)
    guard !Task.isCancelled else { return }
    projectList.commitSnapshot(prepared, serverId: serverId)
    if let workspaceSync {
      do {
        snapshot = try await workspaceSync.migrateNavigationSnapshot(snapshot, serverId: serverId, client: client)
      } catch { navigationSynchronizationFailed(String(describing: error), serverId: serverId, client: client); return }
      guard !Task.isCancelled else { return }
      if snapshot.eventCursor != initialCursor {
        let migrated = await ServerNavigationSnapshotBuilder.build(
          projects: snapshot.projects, sessions: snapshot.sessions, serverId: serverId)
        guard !Task.isCancelled else { return }
        projectList.commitSnapshot(migrated, serverId: serverId)
      }
      workspaceSync.applyNavigationSnapshot(snapshot, serverId: serverId)
    }
    connection(for: serverId).navigationSnapshot = snapshot
    startEventSync(serverId: serverId, client: client, since: snapshot.eventCursor)
    for session in projectList.sessions where session.serverId == serverId {
      onSessionStateChanged?(session, nil)
    }
    let connection = connection(for: serverId)
    connection.navigationSyncState = .current
    connection.navigationFailures = 0
    connection.navigationRetryTask?.cancel()
    connection.navigationRetryTask = nil
  }
}
