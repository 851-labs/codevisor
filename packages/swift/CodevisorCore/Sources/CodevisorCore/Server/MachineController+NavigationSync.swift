import Foundation

extension MachineController {
    /// The only event kinds `handleSyncEvent` acts on. Everything else on the
    /// global socket — most of it per-token `session.output` chunks from every
    /// streaming session — is filtered inside the client's stream task so it
    /// never pays a main-actor hop just to hit the `default:` case below.
    static let shellSyncEventKinds: Set<String> = [
        "project.created", "project.updated", "project.deleted",
        "worktree.created",
        "session.created", "session.updated", "session.deleted",
        "session.attention.updated", "session.archived", "session.unarchived",
        "workspace.updated", "workspace.deleted",
        "workspace.pane.updated", "workspace.pane.deleted",
        "harness.lifecycle.updated",
        "plugin.state.updated",
        "plugin.updated",
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
            var cursor = max(0, initialCursor)
            do {
                for try await event in client.shellEventStream(
                    since: cursor,
                    handledKinds: Self.shellSyncEventKinds
                ) {
                    guard let self, !Task.isCancelled else { return }
                    cursor = max(cursor, event.id)
                    connection.reconnectFailures = 0
                    await self.handleSyncEvent(
                        event,
                        serverId: serverId,
                        client: client
                    )
                }
                guard !Task.isCancelled else { return }
                connection.eventSyncTask = nil
            } catch {
                Log.machines.error(
                    "Event sync for \(serverId, privacy: .public) failed; resubscribing: \(String(describing: error), privacy: .public)"
                )
                guard let self, !Task.isCancelled else { return }
                connection.eventSyncTask = nil
                // Every machine owns the same serialized recovery path. One
                // machine's stream failure never promotes it to a global
                // selection or blocks another machine's snapshot.
                connection.reconnectFailures += 1
                let delay = min(60, 1 << min(connection.reconnectFailures, 6))
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self.synchronizeNavigationState(
                    serverId: serverId,
                    client: client,
                    presentation: .catchUp
                )
            }
        }
    }

    /// Stops every machine's event stream (app teardown and tests).
    public func stopEventSync() {
        for connection in connectionsById.values {
            connection.eventSyncTask?.cancel()
            connection.eventSyncTask = nil
            connection.pendingRefreshTask?.cancel()
            connection.pendingRefreshTask = nil
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
        case "project.deleted":
            if let id = UUID(uuidString: event.subjectId) {
                projectList.removeProjectLocally(id: id, serverId: serverId)
            }
        case "session.deleted":
            if let id = UUID(uuidString: event.subjectId) {
                let membershipChanged = projectList.removeSessionLocally(
                    id: id,
                    serverId: serverId
                )
                if membershipChanged {
                    await workspaceSync?.refreshFromServer(
                        serverId: serverId,
                        client: client
                    )
                }
            }
        case "workspace.deleted":
            if let id = UUID(uuidString: event.subjectId) {
                workspaceSync?.removeWorkspace(id: id, serverId: serverId)
            }
        case "session.created", "session.updated", "session.attention.updated",
            "session.archived", "session.unarchived":
            switch await projectList.applyServerSessionEvent(event, serverId: serverId) {
            case let .applied(workspaceMembershipChanged):
                if workspaceMembershipChanged {
                    await workspaceSync?.refreshFromServer(
                        serverId: serverId,
                        client: client
                    )
                }
            case .requiresFullRefresh:
                // Older servers may emit only an event marker. Retain a
                // compatibility path, but keep it off the ordinary hot path.
                scheduleNavigationRefresh(serverId: serverId, client: client)
            }
        case "workspace.updated", "workspace.pane.updated", "workspace.pane.deleted":
            await workspaceSync?.refreshFromServer(serverId: serverId, client: client)
        case "project.created", "project.updated", "worktree.created":
            scheduleNavigationRefresh(serverId: serverId, client: client)
        case "harness.lifecycle.updated":
            // Update detection / install progress changed a harness — bump
            // the catalog revision so mounted pickers and settings refetch.
            onHarnessLifecycleChanged?(serverId)
        case "plugin.state.updated":
            // A plugin started, stopped, crashed, or the installed list
            // changed — bump the revision so state chips and cards refetch.
            onPluginStateChanged?(serverId)
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
    private func scheduleNavigationRefresh(
        serverId: String,
        client: any CodevisorServerClienting
    ) {
        let connection = connection(for: serverId)
        guard connection.pendingRefreshTask == nil else { return }
        connection.pendingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
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
            // `.current` machines keep their rows on screen while a warm
            // resync runs (see beginWaiting): the blocking catch-up state is
            // only for machines with nothing current to show.
            if presentation == .catchUp, connection.navigationSyncState != .current {
                connection.navigationSyncState = .catchingUp
            }
            await existing.value
            // The joined task's terminal write can race the blocking write
            // above (it may already be past its state-set when we joined).
            // A blocking state must never be left displayed with no task
            // running to clear it — re-enter once with the field clear.
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
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, connection.navigationSyncToken == token
            else { return }
            task.cancel()
            connection.navigationSyncState = .stale(
                "Timed out syncing with this machine."
            )
        }
        await task.value
        watchdog.cancel()
        if connection.navigationSyncToken == token {
            connection.navigationSyncToken = nil
            connection.navigationSyncTask = nil
        }
    }

    /// Stops live application before taking the snapshot. The cursor is
    /// captured after the old consumer is cancelled and before either list is
    /// fetched; the replacement stream therefore replays every event that can
    /// race the snapshot. No live event is allowed to invalidate and silently
    /// discard the authoritative response.
    private func performNavigationSynchronization(
        serverId: String,
        client: any CodevisorServerClienting,
        presentation: NavigationSyncPresentation
    ) async {
        guard !Task.isCancelled else { return }
        // A warm resync of a `.current` machine stays `.current`: its cached
        // rows are honest (the cursor below replays every gap), and demoting
        // them evicted the machine's whole row set from fleet-aggregated
        // lists just to reinsert it seconds later.
        if presentation == .catchUp,
            connection(for: serverId).navigationSyncState != .current
        {
            connection(for: serverId).navigationSyncState = .catchingUp
        }
        stopEventSync(for: serverId)

        let cursor: Int
        do {
            cursor = try await client.latestShellEventCursor()
        } catch {
            // Older servers return the protocol default (zero). A transient
            // cursor failure also falls back to replaying the durable log from
            // zero: more work, but never a correctness gap.
            cursor = 0
            Log.sync.error(
                "Failed to capture navigation cursor for \(serverId, privacy: .public); replaying from zero: \(String(describing: error), privacy: .public)"
            )
        }

        guard !Task.isCancelled else { return }
        let result = await projectList.refreshFromServer(serverId: serverId, client: client)
        guard !Task.isCancelled else { return }

        switch result {
        case .committed:
            await workspaceSync?.refreshFromServer(serverId: serverId, client: client)
            guard !Task.isCancelled else { return }
            startEventSync(serverId: serverId, client: client, since: cursor)
            connection(for: serverId).navigationSyncState = .current
        case .superseded:
            return
        case let .failed(message):
            // Keep the cache visible and continue listening from the captured
            // cursor, but do not claim it is current. A retry or the stream's
            // own recovery will run this same reconciliation path again.
            startEventSync(serverId: serverId, client: client, since: cursor)
            connection(for: serverId).navigationSyncState = .stale(message)
        }
    }
}
