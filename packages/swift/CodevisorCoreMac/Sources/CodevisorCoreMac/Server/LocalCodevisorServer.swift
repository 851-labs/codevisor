import CodevisorCore
import Foundation
import Observation

public struct LocalCodevisorServerLaunchRequest: Equatable, Sendable {
  public var nodeExecutable: URL
  public var entrypoint: URL
  public var databasePath: String
  public var logURL: URL
  public var host: String
  public var port: Int
  public var name: String
  public var bootId: String = "test-boot"
  public var ownerPid: Int32 = 1
  public var environment: [String: String]
  public var dataUpgradeStatusURL: URL? = nil
}

struct LocalCodevisorServerProcessConfiguration: Equatable {
  var executableURL: URL
  var arguments: [String]
}

@MainActor
@Observable
public final class LocalCodevisorServer: LocalServerControlling {
  public typealias Launcher = @MainActor (LocalCodevisorServerLaunchRequest) throws -> Process
  public typealias ServerEnvironmentProvider = @MainActor () async -> [String: String]
  public typealias ListenerTerminator = @MainActor (Int) async -> Void

  let client: any CodevisorServerClienting
  let config: CodevisorServerConfig
  let entrypoint: URL?
  private let nodeExecutable: URL
  private let databasePath: String
  let logURL: URL
  let dataUpgradeStatusURL: URL
  private let computerUseBridge: ComputerUseBridge?
  private let launcher: Launcher
  private let serverEnvironmentProvider: ServerEnvironmentProvider
  private let staleListenerTerminator: ListenerTerminator
  let healthPollInterval: Duration
  let healthPollAttempts: Int
  private let managedStartupPollAttempts: Int
  /// App-hosted servers are owned by exactly one app boot. The server also
  /// watches this app's PID and exits if the app crashes, preventing an
  /// updater backup or stale process from becoming the next launch's server.
  var process: Process?
  var activeBootId: String?
  var managedService: LocalCodevisorManagedService?
  var updateRequestMonitor: Task<Void, Never>?
  /// Event-driven replacement for the old 1 Hz stat poll; watches the
  /// request file's directory. The Task above survives only as the
  /// fallback when the directory can't be opened for events.
  var updateRequestSource: (any DispatchSourceFileSystemObject)?
  /// In-flight `ensureRunning()`; concurrent callers (onboarding and the
  /// root view both prepare the machine on first launch) join it instead of
  /// racing past `currentHealth()` and double-launching the server.
  private var ensureTask: Task<LocalCodevisorServerState, Never>?

  public internal(set) var state: LocalCodevisorServerState = .idle
  /// Sidecar progress remains available while the new server is performing
  /// its blocking migration and therefore cannot answer HTTP yet.
  public internal(set) var dataUpgradeProgress: LocalDataUpgradeProgress?

  /// Invoked when the bundled server exits asking the app to take over the
  /// update: a remote client triggered a server update, but a server that
  /// lives inside the .app bundle can't replace that bundle, so it hands the
  /// update back here. The app runs its full update (swap bundle + relaunch).
  public var onUpdateRequested: (@MainActor () -> Void)?

  /// Exit status the bundled server uses to ask the app to perform the
  /// update instead of self-swapping a standalone runtime. Must match
  /// `APP_UPDATE_HANDOFF_EXIT_CODE` in apps/server/src/main.ts.
  public static let updateHandoffExitStatus: Int32 = 85

  public init(
    client: any CodevisorServerClienting,
    config: CodevisorServerConfig = .localDefault,
    entrypoint: URL? = LocalCodevisorServer.defaultEntrypoint(),
    nodeExecutable: URL = LocalCodevisorServer.defaultNodeExecutable(),
    databasePath: String = LocalCodevisorServer.defaultDatabasePath(),
    logURL: URL = LocalCodevisorServer.defaultLogURL(),
    dataUpgradeStatusURL: URL = LocalCodevisorServer.defaultDataUpgradeStatusURL(),
    computerUseBridge: ComputerUseBridge? = nil,
    serverEnvironmentProvider: @escaping ServerEnvironmentProvider = LocalCodevisorServer.defaultServerEnvironment,
    launcher: @escaping Launcher = LocalCodevisorServer.launchProcess,
    healthPollInterval: Duration = .milliseconds(250),
    healthPollAttempts: Int = 2400,
    managedStartupPollAttempts: Int = 40,
    staleListenerTerminator: @escaping ListenerTerminator = {
      await LocalCodevisorServer.terminateListeners(onPort: $0)
    }
  ) {
    self.client = client
    self.config = config
    self.entrypoint = entrypoint
    self.nodeExecutable = nodeExecutable
    self.databasePath = databasePath
    self.logURL = logURL
    self.dataUpgradeStatusURL = dataUpgradeStatusURL
    self.computerUseBridge = computerUseBridge
    self.serverEnvironmentProvider = serverEnvironmentProvider
    self.launcher = launcher
    self.healthPollInterval = healthPollInterval
    self.healthPollAttempts = healthPollAttempts
    self.managedStartupPollAttempts = managedStartupPollAttempts
    self.staleListenerTerminator = staleListenerTerminator
  }

  public func configureManagedService(_ service: LocalCodevisorManagedService) {
    managedService = service
  }

  @discardableResult
  public func ensureRunning() async -> LocalCodevisorServerState {
    if let ensureTask {
      return await ensureTask.value
    }
    let task = Task { await performEnsureRunning() }
    ensureTask = task
    defer { ensureTask = nil }
    return await task.value
  }

  private func performEnsureRunning() async -> LocalCodevisorServerState {
    let computerUseConfiguration: ComputerUseBridge.Configuration?
    do {
      computerUseConfiguration = try computerUseBridge?.start()
    } catch {
      computerUseConfiguration = nil
      Log.server.error(
        "Computer Use bridge failed to start: \(String(describing: error), privacy: .public)"
      )
    }
    if let managedService {
      do {
        // Platform migrations must run before the first health probe:
        // a legacy KeepAlive job can otherwise answer that probe and
        // restart faster than the stale-listener shutdown path.
        try await managedService.prepare()
      } catch {
        state = .unavailable(
          "Codevisor could not prepare its background service: \(String(describing: error))"
        )
        return state
      }
    }
    if let health = await currentHealth() {
      if let activeBootId, health.bootId == activeBootId {
        dataUpgradeProgress = nil
        state = .alreadyRunning
        return state
      }

      if managedService != nil,
        health.serviceManaged == true,
        healthMatchesBundledRuntime(health)
      {
        startUpdateRequestMonitor()
        dataUpgradeProgress = nil
        state = .alreadyRunning
        return state
      }

      // Development runs deliberately use the standalone server started
      // by `bun run dev`; it has no bundled VERSION and is not app-owned.
      // Production app boots never adopt an unowned or previous app's
      // process merely because something answered on the expected port.
      if bundledServerVersion() == nil, health.appOwned != true {
        dataUpgradeProgress = nil
        state = .alreadyRunning
        return state
      }

      if health.serviceManaged == true {
        try? await managedService?.stop()
      }
      let stopped = await stopStaleServer()
      guard stopped else {
        state = .unavailable(
          "Another Codevisor server is still running and could not be stopped."
        )
        return state
      }
    }

    if let process, process.isRunning {
      return await waitUntilHealthy(process: process, expectedBootId: activeBootId)
    }

    guard let entrypoint else {
      state = .unavailable("Codevisor server entrypoint was not found")
      return state
    }

    // Relocate pre-canonical server state now that no server is serving
    // it: any healthy-but-stale server was stopped above, and the launch
    // below opens the database at the canonical path.
    if databasePath == Self.defaultDatabasePath() {
      Self.migrateLegacyServerData()
    }

    if let managedService {
      do {
        try await managedService.start()
        startUpdateRequestMonitor()
        let managedState = await waitUntilHealthy(
          process: nil,
          expectedBootId: nil,
          requiresBundledIdentity: true,
          initialAttemptLimit: managedStartupPollAttempts,
          extendsForDataUpgrade: true
        )
        if case .unavailable = managedState {
          // Registration is not proof that the agent's executable
          // stayed alive. Tear down a job whose script exited or
          // never bound the port, then continue into the app-owned
          // child process path below.
          try? await managedService.stop()
          await staleListenerTerminator(port)
          state = .idle
          Log.server.error(
            "Managed server did not become healthy; using app-owned fallback"
          )
        } else {
          return managedState
        }
      } catch {
        // A user may disable the background item in System Settings.
        // Keep the app functional with the old child-process lifecycle
        // and scope the failure to durability rather than the server.
        Log.server.error(
          "Managed server unavailable; using app-owned fallback: \(String(describing: error), privacy: .public)"
        )
      }
    }

    do {
      let bootId = UUID().uuidString
      activeBootId = bootId
      var serverEnvironment = await serverEnvironmentProvider()
      // Marks this server as launched by (and living inside) the app
      // bundle, so its self-updater hands app-bundle updates back to us
      // instead of swapping a standalone runtime the next app launch
      // would discard.
      serverEnvironment["CODEVISOR_APP_HOSTED"] = "1"
      if let computerUseConfiguration {
        serverEnvironment["CODEVISOR_COMPUTER_USE_SOCKET"] = computerUseConfiguration.socketPath
        serverEnvironment["CODEVISOR_COMPUTER_USE_TOKEN"] = computerUseConfiguration.token
      }
      let request = LocalCodevisorServerLaunchRequest(
        nodeExecutable: nodeExecutable,
        entrypoint: entrypoint,
        databasePath: databasePath,
        logURL: logURL,
        host: Self.bindHost,
        port: port,
        name: Self.serverDisplayName(),
        bootId: bootId,
        ownerPid: ProcessInfo.processInfo.processIdentifier,
        environment: serverEnvironment,
        dataUpgradeStatusURL: dataUpgradeStatusURL
      )
      let launched = try launcher(request)
      process = launched
      observeTermination(of: launched)
      return await waitUntilHealthy(process: launched, expectedBootId: bootId)
    } catch {
      activeBootId = nil
      state = .unavailable(String(describing: error))
      return state
    }
  }

  /// Stops launchd ownership before Sparkle replaces the bundle, then waits
  /// for the old runtime to release its executable and database lease.
  @discardableResult
  public func prepareForAppUpdate() async -> Bool {
    updateRequestMonitor?.cancel()
    updateRequestMonitor = nil
    updateRequestSource?.cancel()
    updateRequestSource = nil
    try? await managedService?.stop()
    return await shutdown()
  }

  /// Stops the running local server so a newer bundled runtime can take over
  /// on the next launch. Asks politely over HTTP first (the server may not be
  /// a process we own), then force-terminates any owned process that lingers.
  @discardableResult
  public func shutdown() async -> Bool {
    do {
      try await client.requestShutdown()
    } catch {
      // Expected when the server is already gone; termination follows.
      Log.server.debug(
        "Shutdown request failed: \(String(describing: error), privacy: .public)"
      )
    }
    // The server acknowledges shutdown before exiting so the response can
    // flush. Give that contract one bounded grace period, then escalate.
    try? await Task.sleep(for: .milliseconds(400))
    if !(await isHealthy()) {
      finishShutdown()
      return true
    }
    if let process, process.isRunning {
      process.terminate()
      try? await Task.sleep(for: .milliseconds(300))
    }
    if !(await isHealthy()) {
      finishShutdown()
      return true
    }
    await staleListenerTerminator(port)
    for _ in 0..<30 {
      if !(await isHealthy()) {
        finishShutdown()
        return true
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func finishShutdown() {
    process = nil
    activeBootId = nil
    dataUpgradeProgress = nil
    state = .idle
  }
}
