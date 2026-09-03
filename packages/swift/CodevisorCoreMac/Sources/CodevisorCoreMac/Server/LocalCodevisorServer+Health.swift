import CodevisorCore
import Foundation
import Observation

extension LocalCodevisorServer {
  /// The version stamped into the bundled runtime next to its entrypoint.
  /// Nil identifies development, where `bun run dev` intentionally owns the
  /// standalone server and the native app joins it instead of replacing it.
  func bundledServerVersion() -> String? {
    guard let entrypoint else { return nil }
    let versionURL = entrypoint.deletingLastPathComponent().appendingPathComponent("VERSION")
    let raw: String
    do {
      raw = try String(contentsOf: versionURL, encoding: .utf8)
    } catch {
      // Expected in development runs, where no VERSION file is stamped.
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

  /// Stops a server owned by a previous app boot. The shutdown path first
  /// uses the API, then the Process handle, then the confirmed port listener.
  func stopStaleServer() async -> Bool {
    await shutdown()
  }

  /// Sends SIGTERM to processes listening on the port. Only ever invoked
  /// against a confirmed stale Codevisor server that ignored `POST /v1/shutdown`.
  nonisolated public static func terminateListeners(onPort port: Int) async {
    let ownPid = ProcessInfo.processInfo.processIdentifier
    for pid in await listeningPids(onPort: port) where pid != ownPid {
      kill(pid, SIGTERM)
    }
  }

  nonisolated private static func listeningPids(onPort port: Int) async -> [pid_t] {
    await withCheckedContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
      process.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      process.terminationHandler = { _ in
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let pids = String(decoding: data, as: UTF8.self)
          .split(whereSeparator: \.isNewline)
          .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        continuation.resume(returning: pids)
      }
      do {
        try process.run()
      } catch {
        Log.server.debug(
          "lsof probe for port listeners failed: \(String(describing: error), privacy: .public)"
        )
        process.terminationHandler = nil
        continuation.resume(returning: [])
      }
    }
  }

  func currentHealth() async -> ServerHealth? {
    do {
      let health = try await client.health()
      return health.ok ? health : nil
    } catch {
      // Expected when no server is running yet; launch follows.
      Log.server.debug(
        "Health probe failed: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  /// The server binds every interface so paired remote clients can reach it;
  /// only same-machine connections are exempt from its token auth. The app's
  /// own client still talks to it over loopback (`config.baseURL`).
  static let bindHost = "0.0.0.0"

  /// The server's advertised display name: the Mac's name, so a remote
  /// client's machine list shows "George's MacBook Pro 0.2.0" rather than a
  /// generic label.
  nonisolated static func serverDisplayName() -> String {
    CodevisorMachine.local.name
  }

  var port: Int {
    config.baseURL.port ?? CodevisorServerConfig.localPort
  }

  func isHealthy() async -> Bool {
    do {
      return try await client.health().ok
    } catch {
      return false
    }
  }

  /// Consecutive "no live process" answers from the job probe before a
  /// managed server is declared dead: launchd needs a moment after
  /// registration to spawn the job, and one probe can race that.
  static let deadJobProbeThreshold = 3
  /// Health attempts between job probes and between progress log lines.
  static let healthProbeReportEvery = 8

  func waitUntilHealthy(
    process: Process?,
    expectedBootId: String?,
    requiresBundledIdentity: Bool = false,
    initialAttemptLimit: Int? = nil,
    extendsForDataUpgrade: Bool = false,
    jobProbe: (@MainActor () async -> Bool?)? = nil
  ) async -> LocalCodevisorServerState {
    // Breaking data upgrades are allowed to take minutes. Progress comes
    // from the sidecar, so this wait is bounded generously without making
    // the UI appear frozen. A managed job that launchd confirms is alive is
    // likewise given the full budget: a slow boot (a big terminal-buffer
    // restore, a login-shell PATH probe) is not a dead job.
    var attempt = 0
    var attemptLimit = initialAttemptLimit ?? healthPollAttempts
    var lastProbeError = "none"
    var deadJobProbes = 0
    while attempt < attemptLimit {
      attempt += 1
      refreshDataUpgradeProgress(expectedBootId: expectedBootId)
      if extendsForDataUpgrade, dataUpgradeProgress?.state == "running" {
        attemptLimit = max(attemptLimit, healthPollAttempts)
      }
      do {
        let health = try await client.health()
        if health.ok {
          guard expectedBootId == nil || health.bootId == expectedBootId else {
            return fail(
              "A different Codevisor server answered while the local server was starting (boot \(health.bootId ?? "?"), expected \(expectedBootId ?? "?"))."
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
      // Also probe on the last budgeted attempt: a managed job launchd
      // confirms alive earns the full budget instead of failing here.
      if attempt % Self.healthProbeReportEvery == 0 || attempt == attemptLimit {
        var jobNote = ""
        if let jobProbe {
          switch await jobProbe() {
          case .some(true):
            deadJobProbes = 0
            attemptLimit = max(attemptLimit, healthPollAttempts)
            jobNote = ", launchd job running"
          case .some(false):
            deadJobProbes += 1
            jobNote = ", launchd job has no process (\(deadJobProbes)/\(Self.deadJobProbeThreshold))"
            if deadJobProbes >= Self.deadJobProbeThreshold {
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
      try? await Task.sleep(for: healthPollInterval)
    }
    return fail(
      "Timed out waiting for Codevisor server after \(attempt) attempt(s) (last probe: \(lastProbeError)). See \(logURL.path)"
    )
  }

  /// Records a wait failure in the timeline and the observable state.
  private func fail(_ message: String) -> LocalCodevisorServerState {
    lifecycleLog.error("waitUntilHealthy: \(message)")
    state = .unavailable(message)
    return state
  }

  private func refreshDataUpgradeProgress(expectedBootId: String?) {
    // A missing status file is the normal no-upgrade-running case (and
    // this polls, so it stays unlogged); a file that exists but doesn't
    // decode hides real upgrade progress.
    guard let data = try? Data(contentsOf: dataUpgradeStatusURL) else { return }
    do {
      let progress = try JSONDecoder().decode(LocalDataUpgradeProgress.self, from: data)
      guard expectedBootId == nil || progress.bootId == expectedBootId else {
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
