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

  func waitUntilHealthy(
    process: Process?,
    expectedBootId: String?,
    requiresBundledIdentity: Bool = false,
    initialAttemptLimit: Int? = nil,
    extendsForDataUpgrade: Bool = false
  ) async -> LocalCodevisorServerState {
    // Breaking data upgrades are allowed to take minutes. Progress comes
    // from the sidecar, so this wait is bounded generously without making
    // the UI appear frozen.
    var attempt = 0
    var attemptLimit = initialAttemptLimit ?? healthPollAttempts
    while attempt < attemptLimit {
      attempt += 1
      refreshDataUpgradeProgress(expectedBootId: expectedBootId)
      if extendsForDataUpgrade, dataUpgradeProgress?.state == "running" {
        attemptLimit = max(attemptLimit, healthPollAttempts)
      }
      if let health = await currentHealth() {
        guard expectedBootId == nil || health.bootId == expectedBootId else {
          state = .unavailable(
            "A different Codevisor server answered while the local server was starting."
          )
          return state
        }
        guard !requiresBundledIdentity || (health.serviceManaged == true && healthMatchesBundledRuntime(health))
        else {
          state = .unavailable(
            "The local server does not match this Codevisor build."
          )
          return state
        }
        dataUpgradeProgress = nil
        state = .started
        return state
      }
      if let process, !process.isRunning {
        state = .unavailable("Codevisor server exited before becoming ready. See \(logURL.path)")
        return state
      }
      try? await Task.sleep(for: healthPollInterval)
    }
    state = .unavailable("Timed out waiting for Codevisor server. See \(logURL.path)")
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
