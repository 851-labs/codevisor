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
  public var bootId: String
  public var ownerPid: Int32
  public var environment: [String: String]
  public var dataUpgradeStatusURL: URL? = nil
}

struct LocalCodevisorServerProcessConfiguration: Equatable {
  var executableURL: URL
  var arguments: [String]
}

private enum RunningServerAdoption {
  case ownBoot
  case managedService
  case developmentServer
  case standaloneServer
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
  private let adoptsStandaloneServer: Bool
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
  let lifecycleLog: ServerLifecycleLog
  public internal(set) var startupStep: String?
  var process: Process?
  var activeBootId: String?
  var managedService: LocalCodevisorManagedService?
  var updateRequestMonitor: Task<Void, Never>?
  var updateRequestSource: (any DispatchSourceFileSystemObject)?
  var ensureTask: Task<LocalCodevisorServerState, Never>?

  var preparingForUpdate = false

  public internal(set) var state: LocalCodevisorServerState = .idle
  public internal(set) var dataUpgradeProgress: LocalDataUpgradeProgress?

  public var onUpdateRequested: (@MainActor () -> Void)?

  public static let updateHandoffExitStatus: Int32 = 85

  @ObservationIgnored var startupScheduler: LocalServerScheduler = .continuous

  static let bindHost = "0.0.0.0"

  nonisolated static func serverDisplayName() -> String {
    CodevisorMachine.local.name
  }

  var port: Int {
    config.baseURL.port ?? CodevisorServerConfig.localPort
  }

  func adoptClaimedPort() {
    guard case let .localServer(endpoint) = config.address else { return }
    let dataDirectory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
    guard endpoint.adoptClaimedPort(fromDataDirectory: dataDirectory) else { return }
    lifecycleLog.note("The local server claimed port \(endpoint.port)")
  }

  public init(
    client: any CodevisorServerClienting,
    allowsDevelopmentLaunch: Bool = false,
    adoptsStandaloneServer: Bool = false,
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
    self.adoptsStandaloneServer = adoptsStandaloneServer
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
    beginEnsureRunning()
    defer { endEnsureRunning(clock) }

    let computerUse = startComputerUseBridge(&clock)
    if let failure = await prepareManagedService(&clock) { return failure }
    if let settled = await adoptOrStopAnsweringServer(&clock) { return settled }
    if let process, process.isRunning { return await waitForOwnedProcess(process) }
    if adoptsStandaloneServer { return fail("Waiting for this Mac's Codevisor server to start") }
    guard let entrypoint else { return fail("Codevisor server entrypoint was not found") }

    migrateLegacyDataIfDefault(&clock)
    if let managedService { return await startManagedServer(managedService) }
    guard allowsDevelopmentLaunch else {
      return fail("Codevisor's background service is unavailable. Restart Codevisor to register it again.")
    }

    return await launchDevelopmentServer(entrypoint: entrypoint, computerUse: computerUse, clock: &clock)
  }

  private func beginEnsureRunning() {
    startupProgress = LocalServerStartupProgress(stage: "preparingService", completed: 0)
    lifecycleLog.note(
      "ensureRunning: begin (bundled runtime \(bundledServerVersion() ?? "none"), managed service \(managedService == nil ? "absent" : "configured"))"
    )
  }

  private func endEnsureRunning(_ clock: StepClock) {
    startupStep = nil
    lifecycleLog.note("ensureRunning: end → \(state) (\(clock.totalMilliseconds) ms total)")
  }

  private func startComputerUseBridge(_ clock: inout StepClock) -> ComputerUseBridge.Configuration? {
    startupStep = "computer-use bridge"
    let configuration = startedComputerUseBridge()
    lifecycleLog.note("ensureRunning: computer-use bridge ready (\(clock.lap()) ms)")
    return configuration
  }

  private func startedComputerUseBridge() -> ComputerUseBridge.Configuration? {
    do {
      return try computerUseBridge?.start()
    } catch {
      lifecycleLog.error("Computer Use bridge failed to start: \(error)")
      return nil
    }
  }

  private func prepareManagedService(_ clock: inout StepClock) async -> LocalCodevisorServerState? {
    guard let managedService else { return nil }
    startupStep = "prepare managed service"
    do {
      try await managedService.prepare()
    } catch {
      return fail("Codevisor could not prepare its background service: \(error)")
    }
    lifecycleLog.note("ensureRunning: managed service prepared (\(clock.lap()) ms)")
    return nil
  }

  private func adoptOrStopAnsweringServer(_ clock: inout StepClock) async -> LocalCodevisorServerState? {
    startupStep = "health probe"
    guard let health = await currentHealth() else {
      lifecycleLog.note("ensureRunning: no server answering (\(clock.lap()) ms)")
      return nil
    }
    lifecycleLog.note(
      "ensureRunning: a server answered (version \(health.version), boot \(health.bootId ?? "?"), managed \(health.serviceManaged == true), app-owned \(health.appOwned == true)) (\(clock.lap()) ms)"
    )
    if let adoption = adoption(of: health) { return adopt(adoption) }
    return await stopMismatchedServer(&clock)
  }

  private func adoption(of health: ServerHealth) -> RunningServerAdoption? {
    if let activeBootId, health.bootId == activeBootId { return .ownBoot }
    if managedService != nil, health.serviceManaged == true, healthMatchesBundledRuntime(health) {
      return .managedService
    }
    if allowsDevelopmentLaunch, bundledServerVersion() == nil, health.appOwned != true { return .developmentServer }
    if adoptsStandaloneServer, health.appOwned != true { return .standaloneServer }
    return nil
  }

  private func adopt(_ adoption: RunningServerAdoption) -> LocalCodevisorServerState {
    switch adoption {
    case .managedService:
      startUpdateRequestMonitor()
      markAlreadyRunning()
      lifecycleLog.note("ensureRunning: adopting the running managed server")
    case .ownBoot, .developmentServer, .standaloneServer:
      markAlreadyRunning()
    }
    return state
  }

  private func markAlreadyRunning() {
    dataUpgradeProgress = nil
    completeStartup()
    state = .alreadyRunning
  }

  private func stopMismatchedServer(_ clock: inout StepClock) async -> LocalCodevisorServerState? {
    startupStep = "stop stale server"
    lifecycleLog.note("ensureRunning: stopping a stale server that does not match this build")
    let stopped = await shutdown()
    lifecycleLog.note("ensureRunning: stale server \(stopped ? "stopped" : "NOT stopped") (\(clock.lap()) ms)")
    guard stopped else { return fail("Another Codevisor server is still running and could not be stopped.") }
    return nil
  }

  private func waitForOwnedProcess(_ process: Process) async -> LocalCodevisorServerState {
    startupStep = "wait for owned process"
    return await waitUntilHealthy(process: process, expectedBootId: activeBootId)
  }

  private func migrateLegacyDataIfDefault(_ clock: inout StepClock) {
    guard databasePath == Self.defaultDatabasePath() else { return }
    startupStep = "migrate legacy data"
    Self.migrateLegacyServerData()
    lifecycleLog.note("ensureRunning: legacy data check done (\(clock.lap()) ms)")
  }

  private func launchDevelopmentServer(
    entrypoint: URL, computerUse: ComputerUseBridge.Configuration?, clock: inout StepClock
  ) async -> LocalCodevisorServerState {
    startupStep = "launch development server"
    let bootId = beginDevelopmentLaunch()
    let environment = Self.appHostedEnvironment(await serverEnvironmentProvider(), computerUse: computerUse)
    let launched: Process
    do {
      launched = try launcher(launchRequest(entrypoint: entrypoint, bootId: bootId, environment: environment))
    } catch {
      activeBootId = nil
      return fail("Codevisor server could not be launched: \(error)")
    }
    track(launched, bootId: bootId, clock: &clock)

    startupStep = "wait for app-owned server"
    return await waitUntilHealthy(process: launched, expectedBootId: bootId, scheduler: startupScheduler)
  }

  private func beginDevelopmentLaunch() -> String {
    startupAttemptStartedAt = Date()
    startupProgress = LocalServerStartupProgress(stage: "startingProcess", completed: 1)
    let bootId = UUID().uuidString
    activeBootId = bootId
    return bootId
  }

  nonisolated static func appHostedEnvironment(
    _ base: [String: String], computerUse: ComputerUseBridge.Configuration?
  ) -> [String: String] {
    var environment = base
    environment["CODEVISOR_APP_HOSTED"] = "1"
    if let computerUse {
      environment["CODEVISOR_COMPUTER_USE_SOCKET"] = computerUse.socketPath
      environment["CODEVISOR_COMPUTER_USE_TOKEN"] = computerUse.token
    }
    return environment
  }

  private func launchRequest(
    entrypoint: URL, bootId: String, environment: [String: String]
  ) -> LocalCodevisorServerLaunchRequest {
    LocalCodevisorServerLaunchRequest(
      nodeExecutable: nodeExecutable,
      entrypoint: entrypoint,
      databasePath: databasePath,
      logURL: logURL,
      host: Self.bindHost,
      port: port,
      name: Self.serverDisplayName(),
      bootId: bootId,
      ownerPid: ProcessInfo.processInfo.processIdentifier,
      environment: environment,
      dataUpgradeStatusURL: dataUpgradeStatusURL
    )
  }

  private func track(_ launched: Process, bootId: String, clock: inout StepClock) {
    process = launched
    observeTermination(of: launched)
    lifecycleLog.note(
      "ensureRunning: launched app-owned server pid \(launched.processIdentifier) boot \(bootId) (\(clock.lap()) ms)"
    )
  }

  @discardableResult
  private func fail(_ message: String) -> LocalCodevisorServerState {
    lifecycleLog.error("ensureRunning: \(message)")
    state = .unavailable(message)
    captureStartupDiagnostics(message)
    return state
  }

}
