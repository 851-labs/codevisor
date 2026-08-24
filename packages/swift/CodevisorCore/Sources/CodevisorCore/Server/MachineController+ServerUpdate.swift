import Foundation

/// Server self-update orchestration: probing the selected machine's release
/// state and driving a remote update through restart confirmation. Lives in
/// its own file (like the navigation-sync extension) to keep the core
/// controller file within size limits.
extension MachineController {
    /// Refreshes only the selected remote machine's release state. The app
    /// calls this periodically while that machine is open so a release cut
    /// after the initial connection still raises the update banner.
    public func refreshSelectedServerUpdate() async {
        let machineId = selectedMachineId
        guard !selectedMachine.isLocal, serverUpdatePhase != .updating else { return }
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

    /// The selected machine's server update state, when known.
    public var selectedServerUpdate: ServerUpdateInfo? {
        updateInfoByMachineId[selectedMachineId]
    }

    /// Asks the selected machine's server to update itself, then waits for it
    /// to restart into the newer version before refreshing everything and
    /// resubscribing to its event stream.
    public func updateSelectedServer() async {
        guard serverUpdatePhase != .updating else { return }
        let machineId = selectedMachineId
        let client = selectedClient
        let updateChannel = serverUpdateChannel
        let initialVersion = selectedServerUpdate?.currentVersion
        serverUpdatePhase = .updating
        // Close the gate before dispatching the update request. The server
        // may begin shutting down as soon as it handles that endpoint, before
        // the response has made the round trip back to this client.
        beginWaiting(for: machineId, reason: .updating)
        let initialHealth = try? await client.health()
        do {
            let applied = try await client.applyServerUpdate(channel: updateChannel)
            guard applied.accepted else {
                markReady(for: machineId)
                if machineId == selectedMachineId { startEventSync() }
                if applied.reason == "busy" {
                    // The server still has chats mid-turn; updating now would
                    // kill them. The banner disables its button for this app's
                    // own chats, but another client could have started one.
                    serverUpdatePhase = .failed(
                        "This server still has chats running. Wait for them to finish, then update."
                    )
                    return
                }
                // Nothing to do (already up to date); refresh the banner state.
                await refreshStatus(for: machineId)
                serverUpdatePhase = .idle
                return
            }
            // The pre-apply handoff report, so a stale failure left by an
            // earlier attempt is never mistaken for this one's outcome.
            let initialApplyAt = connection(for: machineId).updateInfo?.lastApply?.at
            for _ in 0..<updatePollAttempts {
                try? await Task.sleep(for: updatePollInterval)
                // The user moved on to a different machine; stop waiting.
                guard machineId == selectedMachineId else {
                    serverUpdatePhase = .idle
                    return
                }
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
                    serverUpdatePhase = .failed(
                        lastApply.message ?? "The update failed on the machine."
                    )
                    markReady(for: machineId)
                    if machineId == selectedMachineId { startEventSync() }
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
                    serverUpdatePhase = .idle
                    markReady(for: machineId)
                    await refreshStatus(for: machineId)
                    await projectList.refreshFromServer()
                    startEventSync()
                    return
                }
            }
            let message = "The server did not come back after updating. Check it on the machine directly."
            serverUpdatePhase = .failed(message)
            markFailed(for: machineId, message: message)
        } catch {
            let message = serverErrorMessage(error)
            serverUpdatePhase = .failed(message)
            if (try? await client.info()) != nil {
                markReady(for: machineId)
                if machineId == selectedMachineId { startEventSync() }
            } else {
                markFailed(for: machineId, message: message)
            }
        }
    }
}
