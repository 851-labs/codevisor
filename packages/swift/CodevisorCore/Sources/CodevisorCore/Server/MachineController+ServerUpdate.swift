import Foundation

/// Server self-update orchestration: probing machines' release state and
/// driving a remote update through restart confirmation. Lives in its own
/// file (like the navigation-sync extension) to keep the core controller
/// file within size limits.
extension MachineController {
  public func serverUpdatePhase(for machineId: String) -> ServerUpdatePhase {
    connectionsById[machineId]?.updatePhase ?? .idle
  }

  public var isAnyServerUpdating: Bool {
    connectionsById.values.contains { $0.updatePhase == .updating }
  }

  /// Refreshes one explicit remote machine's release state.
  public func refreshServerUpdate(for machineId: String) async {
    guard let machine = machine(for: machineId), !machine.isLocal,
      connection(for: machineId).updatePhase != .updating
    else { return }
    let client = client(for: machineId)
    do {
      let update = try await client.updateInfo(
        refresh: true,
        channel: serverUpdateChannel
      )
      connection(for: machineId).updateInfo = update
    } catch {
      // A transient background failure should not erase a banner we
      // already know about. The next five-minute pass will retry.
      Log.machines.debug(
        "Periodic update probe for \(machineId, privacy: .public) failed: \(String(describing: error), privacy: .public)"
      )
    }
  }

  /// Sweeps release state for every reachable machine. Machines mid-update are
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

  public func serverUpdateInfo(for machineId: String) -> ServerUpdateInfo? {
    connectionsById[machineId]?.updateInfo
  }

  /// Restores the updated machine's event stream without changing any
  /// composer or navigation preference.
  private func resumeEventStream(for machineId: String) {
    Task { await self.connectMachine(machineId) }
  }

  /// Asks a machine's server to update itself, then waits for it to
  /// restart into the newer version before refreshing its state and
  /// resubscribing to its event stream. Tracks progress on THAT machine's
  /// connection, so the attempt survives the user switching machines. A
  /// server with chats mid-turn drains them first (holding new prompts) and
  /// reports that through `lastApply`; the wait extends while it does.
  public func updateServer(machineId: String) async {
    let connection = connection(for: machineId)
    guard connection.updatePhase != .updating else { return }
    let client = client(for: machineId)
    let updateChannel = serverUpdateChannel
    let initialVersion = connection.updateInfo?.currentVersion
    connection.updatePhase = .updating
    defer { connection.updateStatusMessage = nil }
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
      if applied.draining == true {
        connection.updateStatusMessage = "Waiting for chats to finish…"
      }
      // Deadline-based rather than a fixed attempt count: while the server
      // reports it is still draining live chats, the deadline moves out —
      // the server bounds the drain itself (and interrupts at its own
      // deadline), so this never waits forever.
      let clock = ContinuousClock()
      let pollBudget = updatePollInterval * updatePollAttempts
      var deadline = clock.now + pollBudget
      while clock.now < deadline {
        try? await Task.sleep(for: updatePollInterval)
        // The machine's own progress report: draining, installing (on
        // app-hosted Macs, the host app's headless Sparkle session), or a
        // fresh failure — which ends the wait with the real reason
        // instead of a timeout.
        let update = try? await client.updateInfo(
          refresh: false,
          channel: updateChannel
        )
        if let lastApply = update?.lastApply,
          lastApply.at != initialApplyAt || lastApply.state == "draining"
        {
          switch lastApply.state {
          case "failed":
            connection.updatePhase = .failed(
              lastApply.message ?? "The update failed on the machine."
            )
            markReady(for: machineId)
            resumeEventStream(for: machineId)
            return
          case "draining":
            connection.updateStatusMessage = lastApply.message ?? "Waiting for chats to finish…"
            deadline = max(deadline, clock.now + pollBudget)
            continue
          case "installing":
            connection.updateStatusMessage = lastApply.message ?? "Installing…"
          default:
            break
          }
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
          _ = await projectList.refreshFromServer(serverId: machineId, client: client)
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
