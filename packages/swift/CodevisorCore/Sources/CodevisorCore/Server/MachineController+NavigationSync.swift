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
    ]

    /// Follows the selected server's event stream so projects and sessions
    /// stay in sync across every client connected to that server. Replaces any
    /// previous subscription (e.g. after switching machines).
    public func startEventSync(since initialCursor: Int = 0) {
        startEventSync(
            serverId: selectedMachine.id,
            client: selectedClient,
            since: initialCursor
        )
    }

    func startEventSync(
        serverId: String,
        client: any CodevisorServerClienting,
        since initialCursor: Int
    ) {
        eventSyncTask?.cancel()
        eventSyncTask = Task { [weak self] in
            var cursor = max(0, initialCursor)
            while !Task.isCancelled {
                do {
                    for try await event in client.shellEventStream(
                        since: cursor,
                        handledKinds: Self.shellSyncEventKinds
                    ) {
                        guard let self, !Task.isCancelled else { return }
                        cursor = max(cursor, event.id)
                        await self.handleSyncEvent(
                            event,
                            serverId: serverId,
                            client: client
                        )
                    }
                    return
                } catch {
                    Log.machines.error(
                        "Event sync for \(serverId, privacy: .public) failed; resubscribing: \(String(describing: error), privacy: .public)"
                    )
                    guard let self, !Task.isCancelled else { return }
                    // Re-enter the same serialized snapshot + replay path used
                    // by foreground recovery and manual refresh. Returning is
                    // important: reconciliation installs the replacement
                    // stream and this failed task must not compete with it.
                    await self.synchronizeNavigationState(
                        serverId: serverId,
                        client: client,
                        presentation: .catchUp
                    )
                    return
                }
            }
        }
    }

    public func stopEventSync() {
        eventSyncTask?.cancel()
        eventSyncTask = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
    }

    private func handleSyncEvent(
        _ event: ServerEventEnvelope,
        serverId: String,
        client: any CodevisorServerClienting
    ) async {
        guard serverId == selectedMachine.id else { return }
        DiagnosticsClient.shared.noteSyncEvent(
            machineIsLocal: selectedMachine.isLocal,
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
                scheduleNavigationRefresh()
            }
        case "workspace.updated", "workspace.pane.updated", "workspace.pane.deleted":
            await workspaceSync?.refreshFromServer(serverId: serverId, client: client)
        case "project.created", "project.updated", "worktree.created":
            scheduleNavigationRefresh()
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
        default:
            // Prompt/queue/error events are handled by the session transports.
            break
        }
    }

    /// Coalesces bursts of events (including the initial replay) into a single
    /// refresh from the server.
    private func scheduleNavigationRefresh() {
        guard pendingRefreshTask == nil else { return }
        pendingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.pendingRefreshTask = nil
            let serverId = self.selectedMachine.id
            let client = self.selectedClient
            await self.synchronizeNavigationState(
                serverId: serverId,
                client: client,
                presentation: .background
            )
        }
    }

    /// One shared authoritative navigation reconciliation. Every caller —
    /// launch, foreground recovery, machine switching, event-stream recovery,
    /// and pull-to-refresh — joins this task instead of starting an overlapping
    /// snapshot.
    public func refreshSelectedNavigationState() async {
        let serverId = selectedMachine.id
        await synchronizeNavigationState(
            serverId: serverId,
            client: selectedClient,
            presentation: .background
        )
    }

    func synchronizeNavigationState(
        serverId: String,
        client: any CodevisorServerClienting,
        presentation: NavigationSyncPresentation
    ) async {
        guard serverId == selectedMachine.id else { return }
        if navigationSyncMachineId == serverId, let navigationSyncTask {
            if presentation == .catchUp {
                navigationSyncStateByMachineId[serverId] = .catchingUp
            }
            await navigationSyncTask.value
            return
        }

        navigationSyncTask?.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performNavigationSynchronization(
                serverId: serverId,
                client: client,
                presentation: presentation
            )
        }
        navigationSyncMachineId = serverId
        navigationSyncToken = token
        navigationSyncTask = task
        await task.value
        if navigationSyncToken == token {
            navigationSyncMachineId = nil
            navigationSyncToken = nil
            navigationSyncTask = nil
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
        guard serverId == selectedMachine.id, !Task.isCancelled else { return }
        if presentation == .catchUp {
            navigationSyncStateByMachineId[serverId] = .catchingUp
        }
        stopEventSync()

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

        guard serverId == selectedMachine.id, !Task.isCancelled else { return }
        let result = await projectList.refreshFromServer()
        guard serverId == selectedMachine.id, !Task.isCancelled else { return }

        switch result {
        case .committed:
            await workspaceSync?.refreshFromServer(serverId: serverId, client: client)
            guard serverId == selectedMachine.id, !Task.isCancelled else { return }
            startEventSync(serverId: serverId, client: client, since: cursor)
            navigationSyncStateByMachineId[serverId] = .current
        case .superseded:
            return
        case let .failed(message):
            // Keep the cache visible and continue listening from the captured
            // cursor, but do not claim it is current. A retry or the stream's
            // own recovery will run this same reconciliation path again.
            startEventSync(serverId: serverId, client: client, since: cursor)
            navigationSyncStateByMachineId[serverId] = .stale(message)
        }
    }
}
