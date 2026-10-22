import CodevisorCore
import Foundation

extension LocalCodevisorServer {
  func bundledServerVersion() -> String? {
    guard let entrypoint else { return nil }
    let versionURL = entrypoint.deletingLastPathComponent().appendingPathComponent("VERSION")
    let raw: String
    do {
      raw = try String(contentsOf: versionURL, encoding: .utf8)
    } catch {
      Log.server.debug(
        "No bundled server VERSION file: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func healthMatchesBundledRuntime(_ health: ServerHealth) -> Bool {
    guard let version = bundledServerVersion(), health.version == version else {
      return false
    }
    if let expectedBuild = AppUpdateModel.bundleBuildNumber(),
      health.buildNumber != expectedBuild
    {
      return false
    }
    if let expectedRevision = AppUpdateModel.bundleSourceRevision(),
      health.sourceRevision != expectedRevision
    {
      return false
    }
    return true
  }

  func currentHealth() async -> ServerHealth? {
    adoptClaimedPort()
    do {
      let health = try await StartupDeadline.run(for: .seconds(2), scheduler: startupScheduler) { [client] in
        try await client.health()
      }
      return health.ok ? health : nil
    } catch {
      Log.server.debug(
        "Health probe failed: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  func isHealthy() async -> Bool {
    adoptClaimedPort()
    do {
      return try await StartupDeadline.run(for: .seconds(2), scheduler: startupScheduler) { [client] in
        try await client.health().ok
      }
    } catch {
      return false
    }
  }

  func waitUntilHealthy(
    process: Process?,
    expectedBootId: String?,
    requiresBundledIdentity: Bool = false,
    initialAttemptLimit: Int? = nil,
    jobProbe: (@MainActor () async -> Bool?)? = nil,
    scheduler: LocalServerScheduler = .continuous
  ) async -> LocalCodevisorServerState {
    var watch = StartupHealthWatch(
      expectedBootId: expectedBootId,
      requiresBundledIdentity: requiresBundledIdentity,
      deadline: scheduler.now() + startupMaximumDuration,
      lastProgressAt: scheduler.now(),
      stallTimeout: startupStallTimeout,
      attemptLimit: initialAttemptLimit ?? healthPollAttempts,
      progressAttemptLimit: healthPollAttempts
    )
    while watch.hasAttemptsLeft {
      watch.beginAttempt()
      if Task.isCancelled { return fail("Server startup was cancelled.") }
      refreshProgress(&watch, scheduler: scheduler)
      if let failure = startupFailure(watch, scheduler: scheduler) { return failure }

      if let health = await probeHealth(&watch, scheduler: scheduler) {
        return acceptHealthy(health, from: watch)
      }
      if let process, !process.isRunning { return failExited(process) }

      if watch.isReportDue, let gaveUp = await reportProgress(&watch, jobProbe: jobProbe, scheduler: scheduler) {
        return gaveUp
      }
      try? await scheduler.sleep(healthPollInterval)
    }
    startupCanRetry = true
    return fail(watch.timeoutMessage(logPath: logURL.path))
  }

  private func refreshProgress(_ watch: inout StartupHealthWatch, scheduler: LocalServerScheduler) {
    if refreshStartupProgress(expectedBootId: watch.expectedBootId ?? activeBootId) {
      watch.noteProgress(at: scheduler.now())
    }
    refreshDataUpgradeProgress(expectedBootId: watch.expectedBootId ?? activeBootId)
  }

  private func startupFailure(
    _ watch: StartupHealthWatch, scheduler: LocalServerScheduler
  ) -> LocalCodevisorServerState? {
    if startupProgress?.state == "failed" {
      return fail(startupProgress?.error ?? "The server failed during startup.")
    }
    guard watch.isPastDeadline(at: scheduler.now()) || watch.hasStalled(at: scheduler.now()) else { return nil }
    startupCanRetry = true
    return fail(watch.stalledMessage(waitingOn: startupProgress?.label))
  }

  private func probeHealth(_ watch: inout StartupHealthWatch, scheduler: LocalServerScheduler) async -> ServerHealth? {
    adoptClaimedPort()
    do {
      let health = try await StartupDeadline.run(for: .seconds(2), scheduler: scheduler) { [client] in
        try await client.health()
      }
      if health.ok { return health }
      watch.noteFailedProbe("health not ok")
    } catch {
      watch.noteFailedProbe(String(describing: error))
    }
    return nil
  }

  private func acceptHealthy(_ health: ServerHealth, from watch: StartupHealthWatch) -> LocalCodevisorServerState {
    let boot = watch.expectedBootId ?? activeBootId
    guard boot == nil || health.bootId == boot else {
      return fail(
        "A different Codevisor server answered while the local server was starting (boot \(health.bootId ?? "?"), expected \(boot ?? "?"))."
      )
    }
    guard !watch.requiresBundledIdentity || isBundledManagedServer(health) else {
      return fail(
        "The local server does not match this Codevisor build (server \(health.version) build \(health.buildNumber.map(String.init) ?? "?"), managed \(health.serviceManaged == true))."
      )
    }
    return markStarted(health, after: watch.attempt)
  }

  private func isBundledManagedServer(_ health: ServerHealth) -> Bool {
    health.serviceManaged == true && healthMatchesBundledRuntime(health)
  }

  private func markStarted(_ health: ServerHealth, after attempt: Int) -> LocalCodevisorServerState {
    dataUpgradeProgress = nil
    activeBootId = health.bootId
    completeStartup()
    state = .started
    lifecycleLog.note(
      "waitUntilHealthy: healthy after \(attempt) attempt(s) (version \(health.version), boot \(health.bootId ?? "?"))"
    )
    return state
  }

  private func failExited(_ process: Process) -> LocalCodevisorServerState {
    fail("Codevisor server exited before becoming ready (status \(process.terminationStatus)). See \(logURL.path)")
  }

  private func reportProgress(
    _ watch: inout StartupHealthWatch, jobProbe: (@MainActor () async -> Bool?)?, scheduler: LocalServerScheduler
  ) async -> LocalCodevisorServerState? {
    var jobNote = ""
    if let jobProbe {
      let running = try? await StartupDeadline.run(
        for: .seconds(5), scheduler: scheduler, operation: { await jobProbe() })
      let probe = watch.noteJobProbe(running)
      if probe.givesUp {
        startupCanRetry = true
        return fail(watch.jobExitedMessage(logPath: logURL.path))
      }
      jobNote = probe.text
    }
    lifecycleLog.note(watch.progressReport(jobNote: jobNote))
    return nil
  }

  private func fail(_ message: String) -> LocalCodevisorServerState {
    lifecycleLog.error("waitUntilHealthy: \(message)")
    state = .unavailable(message)
    return state
  }

  private func refreshDataUpgradeProgress(expectedBootId: String?) {
    guard let expectedBootId, let data = try? Data(contentsOf: dataUpgradeStatusURL) else {
      dataUpgradeProgress = nil
      return
    }
    do {
      let progress = try JSONDecoder().decode(LocalDataUpgradeProgress.self, from: data)
      guard progress.bootId == expectedBootId else {
        dataUpgradeProgress = nil
        return
      }
      dataUpgradeProgress = progress
    } catch {
      Log.server.debug(
        "Failed to decode data-upgrade progress: \(String(describing: error), privacy: .public)"
      )
    }
  }
}
