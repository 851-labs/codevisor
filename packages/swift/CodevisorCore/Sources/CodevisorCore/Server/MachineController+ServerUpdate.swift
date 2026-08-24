import Foundation

/// Server self-update orchestration: probing machines' release state and
/// driving a remote update through restart confirmation. Lives in its own
/// file (like the navigation-sync extension) to keep the core controller
/// file within size limits.
extension MachineController {
    /// The SELECTED machine's update progress — a projection kept for the
    /// existing banner and busy-state consumers. The authoritative state is
    /// per machine on its connection, so an update keeps being tracked when
    /// the user switches away and never shows on another machine.
    public var serverUpdatePhase: ServerUpdatePhase {
        connectionsById[selectedMachineId]?.updatePhase ?? .idle
    }

    /// Refreshes only the selected remote machine's release state. The app
    /// calls this while that machine is open so a release cut after the
    /// initial connection still raises the update banner.
    public func refreshSelectedServerUpdate() async {
        let machineId = selectedMachineId
        guard !selectedMachine.isLocal, connection(for: machineId).updatePhase != .updating
        else { return }
        let client = selectedClient
        do {
            let update = try await client.updateInfo(
                refresh: true,
                channel: serverUpdateChannel
            )
            // A machine switch can happen while the request is in flight.
            guard machineId == selectedMachineId else { return }
            connection(for: machineId).updateInfo = update
        } catch {
            // A transient background failure should not erase a banner we
            // already know about. The next five-minute pass will retry.
            Log.machines.debug(
                "Periodic update probe for \(machineId, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Sweeps release state for every reachable machine — the fleet
    /// counterpart to `refreshSelectedServerUpdate`. Machines mid-update are
    /// skipped; `updateServer`'s own polling drives their state. `force`
    /// bypasses each server's check cache and belongs to the user's explicit
    /// "Check Again" — the periodic sweep must NOT force, or every client
    /// hammers the release origin on every pass.
    public func refreshServerUpdates(force: Bool = false) async {
        let machineIds = allMachines.map(\.id).filter { id in
            connectionsById[id]?.status?.isReachable == true
                && connectionsById[id]?.updatePhase != .updating
        }
        for machineId in machineIds {
            let client = client(for: machineId)
            guard
                let update = try? await client.updateInfo(
                    refresh: force,
                    channel: serverUpdateChannel
                )
            else { continue }
            connection(for: machineId).updateInfo = update
        }
    }

    /// The selected machine's server update state, when known.
    public var selectedServerUpdate: ServerUpdateInfo? {
        updateInfoByMachineId[selectedMachineId]
    }

    /// Asks the selected machine's server to update itself.
    public func updateSelectedServer() async {
        await updateServer(machineId: selectedMachineId)
    }

    /// Restores a machine's event stream after an update attempt: the
    /// selected machine re-enters the shared selected-stream path, any other
    /// machine reconnects in the background.
    private func resumeEventStream(for machineId: String) {
        if machineId == selectedMachineId {
            startEventSync()
        } else {
            Task { await self.connectMachine(machineId) }
        }
    }

    /// Asks a machine's server to update itself, then waits for it to
    /// restart into the newer version before refreshing its state and
    /// resubscribing to its event stream. Tracks progress on THAT machine's
    /// connection, so the attempt survives the user switching machines.
    public func updateServer(machineId: String) async {
        let connection = connection(for: machineId)
        guard connection.updatePhase != .updating else { return }
        let client = client(for: machineId)
        let updateChannel = serverUpdateChannel
        let initialVersion = connection.updateInfo?.currentVersion
        connection.updatePhase = .updating
        // Close the gate before dispatching the update request. The server
        // may begin shutting down as soon as it handles that endpoint, before
        // the response has made the round trip back to this client.
        beginWaiting(for: machineId, reason: .updating)
        let initialHealth = try? await client.health()
        do {
            let applied = try await client.applyServerUpdate(channel: updateChannel)
            guard applied.accepted else {
                markReady(for: machineId)
                resumeEventStream(for: machineId)
                if applied.reason == "busy" {
                    // The server still has chats mid-turn; updating now would
                    // kill them. The banner disables its button for this app's
                    // own chats, but another client could have started one.
                    connection.updatePhase = .failed(
                        "This server still has chats running. Wait for them to finish, then update."
                    )
                    return
                }
                // Nothing to do (already up to date); refresh the banner state.
                await refreshStatus(for: machineId)
                connection.updatePhase = .idle
                return
            }
            // The pre-apply handoff report, so a stale failure left by an
            // earlier attempt is never mistaken for this one's outcome.
            let initialApplyAt = connection.updateInfo?.lastApply?.at
            for _ in 0..<updatePollAttempts {
                try? await Task.sleep(for: updatePollInterval)
                // App-hosted servers report their host app's unattended
                // Sparkle session; a fresh failure ends the wait with the
                // machine's real reason instead of a timeout.
                let update = try? await client.updateInfo(
                    refresh: false,
                    channel: updateChannel
                )
                if let lastApply = update?.lastApply,
                    lastApply.state == "failed",
                    lastApply.at != initialApplyAt
                {
                    connection.updatePhase = .failed(
                        lastApply.message ?? "The update failed on the machine."
                    )
                    markReady(for: machineId)
                    resumeEventStream(for: machineId)
                    return
                }
                guard let info = try? await client.info() else { continue }
                var converged = false
                if let targetBuild = applied.targetBuildNumber,
                    let currentBuild = (try? await client.health())?.buildNumber
                {
                    // Build numbers are the one release marker that agrees
                    // across feeds; >= tolerates a machine that jumped past
                    // the target on its own channel.
                    converged = currentBuild >= targetBuild
                } else {
                    // Older servers: version-string heuristics. Alpha
                    // manifests include a prerelease suffix while the
                    // bundled runtime reports its base version, and a remote
                    // Mac may install an even newer release according to its
                    // own Sparkle channel.
                    let exactTargetReached =
                        applied.targetVersion == nil || info.version == applied.targetVersion
                    var restartedWithDifferentVersion =
                        (initialVersion ?? initialHealth?.version).map { info.version != $0 }
                        ?? false
                    if !restartedWithDifferentVersion,
                        let initialBootId = initialHealth?.bootId,
                        let currentBootId = (try? await client.health())?.bootId
                    {
                        restartedWithDifferentVersion = currentBootId != initialBootId
                    }
                    var requestedChannelIsCurrent = false
                    if !exactTargetReached, restartedWithDifferentVersion,
                        let refreshed = try? await client.updateInfo(
                            refresh: true,
                            channel: updateChannel
                        )
                    {
                        requestedChannelIsCurrent = !refreshed.updateAvailable
                    }
                    converged = exactTargetReached || requestedChannelIsCurrent
                }
                if converged {
                    // Clear the spinner as soon as the replacement server is
                    // confirmed.
                    connection.updatePhase = .idle
                    markReady(for: machineId)
                    await refreshStatus(for: machineId)
                    if machineId == selectedMachineId {
                        await projectList.refreshFromServer()
                    }
                    resumeEventStream(for: machineId)
                    return
                }
            }
            let message = "The server did not come back after updating. Check it on the machine directly."
            connection.updatePhase = .failed(message)
            markFailed(for: machineId, message: message)
        } catch {
            let message = serverErrorMessage(error)
            connection.updatePhase = .failed(message)
            if (try? await client.info()) != nil {
                markReady(for: machineId)
                resumeEventStream(for: machineId)
            } else {
                markFailed(for: machineId, message: message)
            }
        }
    }
}
