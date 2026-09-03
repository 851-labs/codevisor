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
  /// The server timeline (server.log + unified log); see ServerLifecycleLog.
  let lifecycleLog: ServerLifecycleLog
  private let safeModeStore: UserDefaults
  /// Where `ensureRunning` currently is, for the watchdog and the failure
  /// message: a start that never returns names the step it stalled in.
  public private(set) var startupStep: String?
  /// True when this boot skipped the managed service on request (a
  /// "Restart in Safe Mode"): the server is an app-owned child.
  public private(set) var isInSafeMode = false
  /// How long a start may take before the watchdog logs the stalled step.
  static let startupWatchdogInterval: Duration = .seconds(20)
  /// UserDefaults key for the one-shot safe-mode request.
  public static let safeModeDefaultsKey = "codevisor.server.safeModeOnNextLaunch"
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
    },
    safeModeStore: UserDefaults = .standard
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
    self.safeModeStore = safeModeStore
    self.lifecycleLog = ServerLifecycleLog(fileURL: logURL)
  }

  public func requestSafeModeOnNextLaunch() {
    safeModeStore.set(true, forKey: Self.safeModeDefaultsKey)
    lifecycleLog.note("Safe mode requested for the next launch")
  }

  private func consumeSafeModeRequest() -> Bool {
    guard safeModeStore.bool(forKey: Self.safeModeDefaultsKey) else { return false }
    safeModeStore.removeObject(forKey: Self.safeModeDefaultsKey)
    return true
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
    var clock = StepClock()
    let safeMode = consumeSafeModeRequest()
    lifecycleLog.note(
      "ensureRunning: begin (bundled runtime \(bundledServerVersion() ?? "none"), managed service \(managedService == nil ? "absent" : "configured")\(safeMode ? ", SAFE MODE requested" : ""))"
    )
    // The watchdog names the step a start stalled in — the one line that
    // was missing when an update left the app on "Starting Codevisor
    // Server" for minutes with nothing in any log.
    let watchdog = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.startupWatchdogInterval)
      guard !Task.isCancelled, let self, let step = self.startupStep else { return }
      self.lifecycleLog.fault(
        "ensureRunning: still in step '\(step)' after \(Self.startupWatchdogInterval)"
      )
    }
    defer {
      watchdog.cancel()
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

    if let managedService, !safeMode {
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
        lifecycleLog.note("ensureRunning: adopting the running managed server")
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

      step("stop stale server")
      lifecycleLog.note("ensureRunning: stopping a stale server that does not match this build")
      if health.serviceManaged == true {
        try? await managedService?.stop()
      }
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

    if let managedService, !safeMode {
      // The managed service is the only production path. It either comes
      // up or this reports exactly why; the app never silently downgrades
      // to a child process that dies with it. "Restart in Safe Mode" is
      // the user's explicit way to do that.
      step("register managed service")
      do {
        try await managedService.start()
        lifecycleLog.note("ensureRunning: managed service registered (\(clock.lap()) ms)")
      } catch {
        return fail("Codevisor's background server could not be started: \(error)")
      }
      startUpdateRequestMonitor()
      step("wait for managed server")
      let managedState = await waitUntilHealthy(
        process: nil,
        expectedBootId: nil,
        requiresBundledIdentity: true,
        initialAttemptLimit: managedStartupPollAttempts,
        extendsForDataUpgrade: true,
        jobProbe: managedService.isJobRunning
      )
      lifecycleLog.note("ensureRunning: managed server wait → \(managedState) (\(clock.lap()) ms)")
      return managedState
    }

    step(safeMode ? "launch app-owned server (safe mode)" : "launch app-owned server")
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
      isInSafeMode = safeMode && managedService != nil
      observeTermination(of: launched)
      lifecycleLog.note(
        "ensureRunning: launched app-owned server pid \(launched.processIdentifier) boot \(bootId)\(isInSafeMode ? " (safe mode)" : "") (\(clock.lap()) ms)"
      )
      step("wait for app-owned server")
      return await waitUntilHealthy(process: launched, expectedBootId: bootId)
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
    return state
  }

  /// How long the app waits for the server's live chats to finish before
  /// asking the server to interrupt them. The server has its own deadline;
  /// this one only guards against a server that never reports drained.
  static let appUpdateDrainTimeout: Duration = .seconds(15 * 60)
  static let appUpdateDrainPollInterval: Duration = .seconds(1)

  /// Drains live chats, stops launchd ownership before Sparkle replaces the
  /// bundle, then waits for the old runtime to release its executable and
  /// database lease. The drain snapshots the live sessions so the updated
  /// server brings them back and dispatches any prompts held meanwhile.
  @discardableResult
  public func prepareForAppUpdate(
    onStatus: @escaping @MainActor (String) -> Void = { _ in }
  ) async -> Bool {
    var clock = StepClock()
    lifecycleLog.note("prepareForAppUpdate: begin")
    updateRequestMonitor?.cancel()
    updateRequestMonitor = nil
    updateRequestSource?.cancel()
    updateRequestSource = nil
    await drainForAppUpdate(onStatus: onStatus)
    lifecycleLog.note("prepareForAppUpdate: drain finished (\(clock.lap()) ms)")
    do {
      try await managedService?.stop()
      lifecycleLog.note("prepareForAppUpdate: managed service stopped (\(clock.lap()) ms)")
    } catch {
      lifecycleLog.error("prepareForAppUpdate: managed service stop failed: \(error)")
    }
    let stopped = await shutdown()
    lifecycleLog.note(
      "prepareForAppUpdate: server \(stopped ? "stopped" : "NOT stopped") (\(clock.lap()) ms, \(clock.totalMilliseconds) ms total)"
    )
    return stopped
  }

  /// Asks the server to drain and polls until it reports drained. A server
  /// that cannot answer (already gone, or predating the drain) is treated as
  /// drained: the shutdown that follows behaves exactly as before.
  private func drainForAppUpdate(onStatus: @escaping @MainActor (String) -> Void) async {
    guard let first = try? await client.beginRestartDrain(interrupt: false) else {
      lifecycleLog.note("prepareForAppUpdate: server has no restart drain (or is not answering)")
      return
    }
    lifecycleLog.note("prepareForAppUpdate: drain \(first.state), \(first.remaining) live turn(s)")
    if first.isDrained { return }
    let clock = ContinuousClock()
    let deadline = clock.now + Self.appUpdateDrainTimeout
    var interrupted = false
    while true {
      guard let state = try? await client.restartDrainState() else { return }
      if state.isDrained { return }
      let chats = state.remaining == 1 ? "1 chat" : "\(state.remaining) chats"
      onStatus("Waiting for \(chats) to finish…")
      if clock.now >= deadline, !interrupted {
        interrupted = true
        lifecycleLog.note("prepareForAppUpdate: drain deadline reached, interrupting live turns")
        _ = try? await client.beginRestartDrain(interrupt: true)
      }
      try? await Task.sleep(for: Self.appUpdateDrainPollInterval)
    }
  }

  public func abandonAppUpdate() async {
    lifecycleLog.note("abandonAppUpdate: releasing the drain")
    try? await client.cancelRestartDrain()
    if await isHealthy() {
      startUpdateRequestMonitor()
      return
    }
    // The server was already stopped for the update: bring it back so the
    // app is usable again without a relaunch.
    lifecycleLog.note("abandonAppUpdate: server is down; starting it again")
    await ensureRunning()
  }

  /// Stops the running local server so a newer bundled runtime can take over
  /// on the next launch. Asks politely over HTTP first (the server may not be
  /// a process we own), then force-terminates any owned process that lingers.
  @discardableResult
  public func shutdown() async -> Bool {
    do {
      try await client.requestShutdown()
      lifecycleLog.note("shutdown: server acknowledged the shutdown request")
    } catch {
      // Expected when the server is already gone; termination follows.
      lifecycleLog.note("shutdown: request not answered (\(error)); escalating")
    }
    // The server acknowledges shutdown before exiting so the response can
    // flush. Give that contract one bounded grace period, then escalate.
    try? await Task.sleep(for: .milliseconds(400))
    if !(await isHealthy()) {
      finishShutdown()
      return true
    }
    if let process, process.isRunning {
      lifecycleLog.note("shutdown: terminating owned process \(process.processIdentifier)")
      process.terminate()
      try? await Task.sleep(for: .milliseconds(300))
    }
    if !(await isHealthy()) {
      finishShutdown()
      return true
    }
    lifecycleLog.note("shutdown: signalling whatever still listens on port \(port)")
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
    isInSafeMode = false
    state = .idle
    lifecycleLog.note("shutdown: server is down")
  }
}
