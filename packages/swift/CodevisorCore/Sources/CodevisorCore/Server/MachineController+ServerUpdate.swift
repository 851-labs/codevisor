import Foundation

extension MachineController {
  static let migrationMaximumDuration: Duration = .seconds(10 * 60)

  public var isAnyServerUpdating: Bool {
    connectionsById.values.contains { $0.updatePhase == .updating }
  }

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

  private func resumeEventStream(for machineId: String) {
    Task { await self.connectMachine(machineId) }
  }

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
    beginWaiting(for: machineId, reason: .updating)
    let initialHealth = try? await client.health()
    do {
      let applied = try await client.applyServerUpdate(channel: updateChannel)
      guard applied.accepted else {
        markReady(for: machineId)
        resumeEventStream(for: machineId)
        if applied.reason == "busy" {
          connection.updatePhase = .failed(
            "This server still has chats running. Wait for them to finish, then update."
          )
          return
        }
        await refreshStatus(for: machineId)
        connection.updatePhase = .idle
        return
      }
      let initialApplyAt = connection.updateInfo?.lastApply?.at
      if applied.draining == true {
        connection.updateStatusMessage = "Waiting for chats to finish…"
      }
      let pollBudget = updatePollInterval * updatePollAttempts
      var deadline = updateScheduler.now() + pollBudget
      var targetBuildNumber = applied.targetBuildNumber
      var lastInstallProgress: Double?
      var lastInstallMessage: String?
      var migrationStartedAt: ContinuousClock.Instant?
      while updateScheduler.now() < deadline {
        try? await updateScheduler.sleep(updatePollInterval)
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
          converged = currentBuild >= targetBuild
        } else {
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
          connection.updatePhase = .idle
          markReady(for: machineId)
          await refreshStatus(for: machineId)
          await refreshNavigationState(for: machineId)
          resumeEventStream(for: machineId)
          return
        }
      }
      if (try? await client.info()) != nil {
        markReady(for: machineId)
        let refreshed = try? await client.updateInfo(refresh: true, channel: updateChannel)
        if let refreshed { connection.updateInfo = refreshed }
        await refreshStatus(for: machineId)
        resumeEventStream(for: machineId)
        guard refreshed?.updateAvailable != false else {
          connection.updatePhase = .idle
          await refreshNavigationState(for: machineId)
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
      scheduleRemoteRecovery(for: machineId)
    } catch {
      let message = serverErrorMessage(error)
      connection.updatePhase = .failed(message)
      if (try? await client.info()) != nil {
        markReady(for: machineId)
        resumeEventStream(for: machineId)
      } else {
        markFailed(for: machineId, message: message)
        scheduleRemoteRecovery(for: machineId)
      }
    }
  }
}
