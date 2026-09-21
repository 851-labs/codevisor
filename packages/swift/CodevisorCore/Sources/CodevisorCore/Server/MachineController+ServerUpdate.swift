import Foundation

/// Server self-update orchestration: probing machines' release state and
/// driving a remote update through restart confirmation. Lives in its own
/// file (like the navigation-sync extension) to keep the core controller
/// file within size limits.
extension MachineController {
  /// How long a replacement server may report a running data upgrade
  /// before the update is declared stuck. Mirrors the local server's
  /// startup budget: migrations are resumable, so a genuine one that runs
  /// this long is wedged, not slow.
  static let migrationMaximumDuration: Duration = .seconds(10 * 60)

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

  /// Why a reachable server is still not on the requested release when
  /// the wait ran out: it restarted onto some other build (the machine's
  /// installer chose differently — try again), or it never restarted.
  static func notConvergedMessage(
    initial: ServerHealth?, current: ServerHealth?, refreshed: ServerUpdateInfo?
  ) -> String {
    let rebooted = initial?.bootId != nil && current?.bootId != nil && initial?.bootId != current?.bootId
    let advanced: Bool =
      if let before = initial?.buildNumber, let after = current?.buildNumber { after > before } else { false }
    guard rebooted || advanced else {
      return "The server is still running the previous version and never restarted. Check it on the machine directly."
    }
    let installed =
      refreshed.map {
        AppUpdateModel.displayedVersion(
          $0.currentVersion, buildNumber: $0.currentBuildNumber, usesAlphaChannel: $0.channel == "alpha")
      } ?? current?.version ?? "a different version"
    let latest = refreshed?.latestVersion ?? "a newer release"
    return "The server restarted into \(installed), but \(latest) is still available. Try updating again."
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
    connection.updateProgress = nil
    connection.updateStatusMessage = nil
    defer {
      connection.updateStatusMessage = nil
      connection.updateProgress = nil
    }
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
      let pollBudget = updatePollInterval * updatePollAttempts
      var deadline = updateScheduler.now() + pollBudget
      // The build to wait for. The accepted target comes from the
      // machine's release check; the install itself may land elsewhere
      // (an app-hosted Mac's Sparkle can resume a download it staged
      // before a newer release appeared), and the machine reports the
      // build it is really installing. Converging on THAT build keeps a
      // successful install from reading as a server that never returned.
      var targetBuildNumber = applied.targetBuildNumber
      var lastInstallProgress: Double?
      var lastInstallMessage: String?
      var migrationStartedAt: ContinuousClock.Instant?
      while updateScheduler.now() < deadline {
        try? await updateScheduler.sleep(updatePollInterval)
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
            connection.updateProgress = nil
            connection.updateStatusMessage = lastApply.message ?? "Waiting for chats to finish…"
            deadline = max(deadline, updateScheduler.now() + pollBudget)
            continue
          case "installing":
            let progress = lastApply.progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            let message = lastApply.message ?? "Installing…"
            // A slow download is healthy while its progress advances. Repeated
            // identical reports do not keep a stalled install alive forever.
            if progress != lastInstallProgress || message != lastInstallMessage {
              deadline = max(deadline, updateScheduler.now() + pollBudget)
            }
            lastInstallProgress = progress
            lastInstallMessage = message
            connection.updateProgress = progress
            connection.updateStatusMessage = message
            if let installing = lastApply.targetBuildNumber, installing != targetBuildNumber {
              targetBuildNumber = installing
              deadline = max(deadline, updateScheduler.now() + pollBudget)
            }
          default:
            break
          }
        }
        // The replacement server is booting through a data upgrade: it
        // answers health with the migration in flight while every other
        // route is refused. Follow it live. Keep waiting while it keeps
        // answering — one long step reports no granular progress — but
        // bounded, so a wedged migration still ends in a failure.
        if let health = await probeDataUpgrade(for: machineId, client: client) {
          let migration = connection.dataUpgradeProgress
          if health.database == "failed" {
            let message = migration?.error ?? "The server couldn't finish updating its data."
            connection.updatePhase = .failed(message)
            markFailed(for: machineId, message: message)
            return
          }
          let startedAt = migrationStartedAt ?? updateScheduler.now()
          migrationStartedAt = startedAt
          if updateScheduler.now() - startedAt < Self.migrationMaximumDuration {
            deadline = max(deadline, updateScheduler.now() + pollBudget)
          }
          connection.updateProgress = migration?.fractionCompleted
          connection.updateStatusMessage =
            migration.map { $0.name.isEmpty ? "Updating server data…" : $0.name }
            ?? "Updating server data…"
          continue
        }
        guard let info = try? await client.info() else {
          connection.updateProgress = nil
          connection.updateStatusMessage = "Restarting…"
          continue
        }
        var converged = false
        if let targetBuild = targetBuildNumber,
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
      // Out of time. A machine that answers is not gone: keep it usable,
      // and say what actually happened instead of "did not come back".
      if (try? await client.info()) != nil {
        markReady(for: machineId)
        let refreshed = try? await client.updateInfo(refresh: true, channel: updateChannel)
        if let refreshed { connection.updateInfo = refreshed }
        await refreshStatus(for: machineId)
        resumeEventStream(for: machineId)
        guard refreshed?.updateAvailable != false else {
          // It landed on the target after all; the deadline just beat it.
          connection.updatePhase = .idle
          _ = await projectList.refreshFromServer(serverId: machineId, client: client)
          return
        }
        connection.updatePhase = .failed(
          Self.notConvergedMessage(
            initial: initialHealth, current: try? await client.health(), refreshed: refreshed))
        return
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
