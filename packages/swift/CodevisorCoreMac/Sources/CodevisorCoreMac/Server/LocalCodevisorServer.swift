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
  let databasePath: String
  private let allowsDevelopmentLaunch: Bool
  let startupStatusURL: URL
  let startupStallTimeout: Duration
  let startupMaximumDuration: Duration
  var startupAttemptStartedAt = Date()
  var startupCanRetry = false
  var shutdownProbe: (@MainActor () async -> Bool)?
  public internal(set) var startupProgress: LocalServerStartupProgress?
  let logURL: URL
  let dataUpgradeStatusURL: URL
  private let computerUseBridge: ComputerUseBridge?
  private let launcher: Launcher
  private let serverEnvironmentProvider: ServerEnvironmentProvider
  let staleListenerTerminator: ListenerTerminator?
  let healthPollInterval: Duration
  let healthPollAttempts: Int
  let managedStartupPollAttempts: Int
  /// The server timeline (server.log + unified log); see ServerLifecycleLog.
  let lifecycleLog: ServerLifecycleLog
  /// Where `ensureRunning` currently is, for the watchdog and the failure
  /// message: a start that never returns names the step it stalled in.
  public internal(set) var startupStep: String?
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
  var ensureTask: Task<LocalCodevisorServerState, Never>?

  var preparingForUpdate = false

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

  @ObservationIgnored var startupScheduler: LocalServerScheduler = .continuous

  public init(
    client: any CodevisorServerClienting,
    allowsDevelopmentLaunch: Bool = false,
    config: CodevisorServerConfig = .localDefault,
    entrypoint: URL? = LocalCodevisorServer.defaultEntrypoint(),
    nodeExecutable: URL = LocalCodevisorServer.defaultNodeExecutable(),
    databasePath: String = LocalCodevisorServer.defaultDatabasePath(),
    logURL: URL = LocalCodevisorServer.defaultLogURL(),
    dataUpgradeStatusURL: URL = LocalCodevisorServer.defaultDataUpgradeStatusURL(),
    startupStatusURL: URL? = nil,
    startupStallTimeout: Duration = .seconds(30),
    startupMaximumDuration: Duration = .seconds(10 * 60),
    computerUseBridge: ComputerUseBridge? = nil,
    serverEnvironmentProvider: @escaping ServerEnvironmentProvider = LocalCodevisorServer.defaultServerEnvironment,
    launcher: @escaping Launcher = LocalCodevisorServer.launchProcess,
    healthPollInterval: Duration = .milliseconds(250),
    healthPollAttempts: Int = 2400,
    managedStartupPollAttempts: Int = 120,
    staleListenerTerminator: ListenerTerminator? = nil,
    shutdownProbe: (@MainActor () async -> Bool)? = nil
  ) {
    self.client = client
    self.allowsDevelopmentLaunch = allowsDevelopmentLaunch
    self.startupStatusURL =
      startupStatusURL
      ?? URL(fileURLWithPath: databasePath).deletingLastPathComponent().appendingPathComponent("server-startup.json")
    self.startupStallTimeout = startupStallTimeout
    self.startupMaximumDuration = startupMaximumDuration
    self.shutdownProbe = shutdownProbe
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
    self.lifecycleLog = ServerLifecycleLog(fileURL: logURL)
  }

  public func configureManagedService(_ service: LocalCodevisorManagedService) {
    managedService = service
  }

  @discardableResult
  public func ensureRunning() async -> LocalCodevisorServerState {
    guard !preparingForUpdate else { return .unavailable("Codevisor is preparing an app update.") }
    if let ensureTask {
      return await ensureTask.value
    }
    let task = Task { await performEnsureRunning() }
    ensureTask = task
    defer { ensureTask = nil }
    return await task.value
  }

  private func performEnsureRunning() async -> LocalCodevisorServerState {
    var clock = StepClock()
    startupProgress = LocalServerStartupProgress(stage: "preparingService", completed: 0)
    lifecycleLog.note(
      "ensureRunning: begin (bundled runtime \(bundledServerVersion() ?? "none"), managed service \(managedService == nil ? "absent" : "configured"))"
    )
    defer {
      startupStep = nil
      lifecycleLog.note("ensureRunning: end → \(state) (\(clock.totalMilliseconds) ms total)")
    }
    let step: (String) -> Void = { [self] name in
      startupStep = name
    }

    step("computer-use bridge")
    let computerUseConfiguration: ComputerUseBridge.Configuration?
    do {
      computerUseConfiguration = try computerUseBridge?.start()
    } catch {
      computerUseConfiguration = nil
      lifecycleLog.error("Computer Use bridge failed to start: \(error)")
    }
    lifecycleLog.note("ensureRunning: computer-use bridge ready (\(clock.lap()) ms)")

    if let managedService {
      step("prepare managed service")
      do {
        // Platform migrations must run before the first health probe:
        // a legacy KeepAlive job can otherwise answer that probe and
        // restart faster than the stale-listener shutdown path.
        try await managedService.prepare()
        lifecycleLog.note("ensureRunning: managed service prepared (\(clock.lap()) ms)")
      } catch {
        return fail("Codevisor could not prepare its background service: \(error)")
      }
    }

    step("health probe")
    if let health = await currentHealth() {
      lifecycleLog.note(
        "ensureRunning: a server answered (version \(health.version), boot \(health.bootId ?? "?"), managed \(health.serviceManaged == true), app-owned \(health.appOwned == true)) (\(clock.lap()) ms)"
      )
      if let activeBootId, health.bootId == activeBootId {
        dataUpgradeProgress = nil
        completeStartup()
        state = .alreadyRunning
        return state
      }

      if managedService != nil,
        health.serviceManaged == true,
        healthMatchesBundledRuntime(health)
      {
        startUpdateRequestMonitor()
        dataUpgradeProgress = nil
        completeStartup()
        state = .alreadyRunning
        lifecycleLog.note("ensureRunning: adopting the running managed server")
        return state
      }

      // Development runs deliberately use the standalone server started
      // by `bun run dev`; it has no bundled VERSION and is not app-owned.
      // Production app boots never adopt an unowned or previous app's
      // process merely because something answered on the expected port.
      if allowsDevelopmentLaunch, bundledServerVersion() == nil, health.appOwned != true {
        dataUpgradeProgress = nil
        completeStartup()
        state = .alreadyRunning
        return state
      }

      step("stop stale server")
      lifecycleLog.note("ensureRunning: stopping a stale server that does not match this build")
      let stopped = await stopStaleServer()
      lifecycleLog.note("ensureRunning: stale server \(stopped ? "stopped" : "NOT stopped") (\(clock.lap()) ms)")
      guard stopped else {
        return fail("Another Codevisor server is still running and could not be stopped.")
      }
    } else {
      lifecycleLog.note("ensureRunning: no server answering (\(clock.lap()) ms)")
    }

    if let process, process.isRunning {
      step("wait for owned process")
      return await waitUntilHealthy(process: process, expectedBootId: activeBootId)
    }

    guard let entrypoint else {
      return fail("Codevisor server entrypoint was not found")
    }

    // Relocate pre-canonical server state now that no server is serving
    // it: any healthy-but-stale server was stopped above, and the launch
    // below opens the database at the canonical path.
    if databasePath == Self.defaultDatabasePath() {
      step("migrate legacy data")
      Self.migrateLegacyServerData()
      lifecycleLog.note("ensureRunning: legacy data check done (\(clock.lap()) ms)")
    }

    if let managedService {
      // Production always uses the managed service.
      return await startManagedServer(managedService)
    }

    guard allowsDevelopmentLaunch else {
      return fail("Codevisor's background service is unavailable. Restart Codevisor to register it again.")
    }

    step("launch development server")
    startupAttemptStartedAt = Date()
    startupProgress = LocalServerStartupProgress(stage: "startingProcess", completed: 1)
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
      lifecycleLog.note(
        "ensureRunning: launched app-owned server pid \(launched.processIdentifier) boot \(bootId) (\(clock.lap()) ms)"
      )
      step("wait for app-owned server")
      return await waitUntilHealthy(process: launched, expectedBootId: bootId, scheduler: startupScheduler)
    } catch {
      activeBootId = nil
      return fail("Codevisor server could not be launched: \(error)")
    }
  }

  /// Records a startup failure in the timeline and the observable state.
  @discardableResult
  private func fail(_ message: String) -> LocalCodevisorServerState {
    lifecycleLog.error("ensureRunning: \(message)")
    state = .unavailable(message)
    captureStartupDiagnostics(message)
    return state
  }

}
