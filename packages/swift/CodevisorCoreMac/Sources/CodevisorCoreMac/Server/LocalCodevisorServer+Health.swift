import CodevisorCore
import Foundation
import Observation

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

  func stopStaleServer() async -> Bool {
    await shutdown()
  }

  func currentHealth() async -> ServerHealth? {
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

  static let bindHost = "0.0.0.0"

  nonisolated static func serverDisplayName() -> String {
    CodevisorMachine.local.name
  }

  var port: Int {
    config.baseURL.port ?? CodevisorServerConfig.localPort
  }

  func isHealthy() async -> Bool {
    do {
      return try await StartupDeadline.run(for: .seconds(2), scheduler: startupScheduler) { [client] in
        try await client.health().ok
      }
    } catch {
      return false
    }
  }

  static let deadJobProbeThreshold = 3
  static let healthProbeReportEvery = 8

  func waitUntilHealthy(
    process: Process?,
    expectedBootId: String?,
    requiresBundledIdentity: Bool = false,
    initialAttemptLimit: Int? = nil,
    jobProbe: (@MainActor () async -> Bool?)? = nil,
    scheduler: LocalServerScheduler = .continuous
  ) async -> LocalCodevisorServerState {
    let deadline = scheduler.now() + startupMaximumDuration
    var lastProgressAt = scheduler.now()
    var attempt = 0
    var attemptLimit = initialAttemptLimit ?? healthPollAttempts
    var lastProbeError = "none"
    var deadJobProbes = 0
    while attempt < attemptLimit {
      attempt += 1
      if Task.isCancelled { return fail("Server startup was cancelled.") }
      if refreshStartupProgress(expectedBootId: expectedBootId ?? activeBootId) {
        lastProgressAt = scheduler.now()
        attemptLimit = max(attemptLimit, healthPollAttempts)
      }
      refreshDataUpgradeProgress(expectedBootId: expectedBootId ?? activeBootId)
      if startupProgress?.state == "failed" {
        return fail(startupProgress?.error ?? "The server failed during startup.")
      }
      if scheduler.now() >= deadline || scheduler.now() - lastProgressAt >= startupStallTimeout {
        startupCanRetry = true
        return fail(
          "Server startup stopped progressing while \(startupProgress?.label.lowercased() ?? "waiting for a response")."
        )
      }
      do {
        let health = try await StartupDeadline.run(for: .seconds(2), scheduler: scheduler) { [client] in
          try await client.health()
        }
        if health.ok {
          let boot = expectedBootId ?? activeBootId
          guard boot == nil || health.bootId == boot else {
            return fail(
              "A different Codevisor server answered while the local server was starting (boot \(health.bootId ?? "?"), expected \(boot ?? "?"))."
            )
          }
          guard
            !requiresBundledIdentity
              || (health.serviceManaged == true && healthMatchesBundledRuntime(health))
          else {
            return fail(
              "The local server does not match this Codevisor build (server \(health.version) build \(health.buildNumber.map(String.init) ?? "?"), managed \(health.serviceManaged == true))."
            )
          }
          dataUpgradeProgress = nil
          activeBootId = health.bootId
          completeStartup()
          state = .started
          lifecycleLog.note(
            "waitUntilHealthy: healthy after \(attempt) attempt(s) (version \(health.version), boot \(health.bootId ?? "?"))"
          )
          return state
        }
        lastProbeError = "health not ok"
      } catch {
        lastProbeError = String(describing: error)
      }
      if let process, !process.isRunning {
        return fail(
          "Codevisor server exited before becoming ready (status \(process.terminationStatus)). See \(logURL.path)"
        )
      }
      if attempt % Self.healthProbeReportEvery == 0 || attempt == attemptLimit {
        var jobNote = ""
        if let jobProbe {
          switch try? await StartupDeadline.run(
            for: .seconds(5), scheduler: scheduler, operation: { await jobProbe() })
          {
          case .some(true):
            deadJobProbes = 0
            jobNote = ", launchd job running"
          case .some(false):
            deadJobProbes += 1
            jobNote = ", launchd job has no process (\(deadJobProbes)/\(Self.deadJobProbeThreshold))"
            if deadJobProbes >= Self.deadJobProbeThreshold {
              startupCanRetry = true
              return fail(
                "Codevisor's background server exited before becoming ready (last probe: \(lastProbeError)). See \(logURL.path)"
              )
            }
          case .none:
            jobNote = ", launchd job state unknown"
          }
        }
        lifecycleLog.note(
          "waitUntilHealthy: attempt \(attempt)/\(attemptLimit), last probe: \(lastProbeError)\(jobNote)"
        )
      }
      try? await scheduler.sleep(healthPollInterval)
    }
    startupCanRetry = true
    return fail(
      "Timed out waiting for Codevisor server after \(attempt) attempt(s) (last probe: \(lastProbeError)). See \(logURL.path)"
    )
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
