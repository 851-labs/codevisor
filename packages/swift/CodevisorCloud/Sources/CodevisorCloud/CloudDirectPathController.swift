import CodevisorClient
import Foundation
import Observation

@MainActor
@Observable
public final class CloudDirectPathController {
  public struct Pipe: Sendable {
    public let connection: CloudDirectConnection
    public let path: @Sendable () -> CloudTunnelPath?

    public init(connection: CloudDirectConnection, path: @escaping @Sendable () -> CloudTunnelPath? = { nil }) {
      self.connection = connection
      self.path = path
    }
  }

  public typealias Prober =
    @Sendable (
      CloudMachine,
      @escaping @Sendable () -> Void
    ) async -> Pipe?

  public private(set) var machineIds: Set<String> = []
  public private(set) var paths: [String: CloudTunnelPath] = [:]
  public private(set) var dialing: Set<String> = []
  public private(set) var lastReachable: [String: Date] = [:]
  public private(set) var allowsDirectPaths = true
  @ObservationIgnored private var pathReaders: [String: @Sendable () -> CloudTunnelPath?] = [:]
  @ObservationIgnored var pathRefresh: Task<Void, Never>?
  static let pathRefreshInterval: Duration = .seconds(5)

  @ObservationIgnored private var connections: [String: (connection: CloudDirectConnection, publicKey: String)] = [:]
  @ObservationIgnored private var connectionGenerations: [String: UUID] = [:]
  @ObservationIgnored var probeTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var retryTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var failures: [String: Int] = [:]
  @ObservationIgnored private var redialedForStreak: Set<String> = []
  @ObservationIgnored private var rebuiltSinceLastPipe = false
  @ObservationIgnored private var endpointRebuild: Task<Void, Never>?
  @ObservationIgnored private var lastAttempt: [String: ContinuousClock.Instant] = [:]
  @ObservationIgnored private var known: [String: CloudMachine] = [:]
  @ObservationIgnored private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
  private let prober: Prober
  private let rebuildEndpoint: @Sendable () async -> Void
  private let reprobeInterval: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  public let tunnel: CloudTunnelEndpoint

  public init(
    credentialStore: any CloudCredentialStore,
    reprobeInterval: Duration = .seconds(60),
    tunnel: CloudTunnelEndpoint? = nil,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    prober: Prober? = nil,
    rebuildEndpoint: (@Sendable () async -> Void)? = nil
  ) {
    let tunnel = tunnel ?? CloudTunnelEndpoint(credentialStore: credentialStore)
    self.tunnel = tunnel
    self.reprobeInterval = reprobeInterval
    self.sleep = sleep
    self.prober = prober ?? Self.defaultProber(credentialStore: credentialStore, tunnel: tunnel)
    self.rebuildEndpoint = rebuildEndpoint ?? { await tunnel.rebuild() }
  }

  @ObservationIgnored public var onTunnelConfigured: (@MainActor () -> Void)?

  @ObservationIgnored public var onPipeUp: (@MainActor (String) -> Void)?

  public func configureTunnel(_ config: CloudTunnelConfig) {
    let tunnel = tunnel
    Task { [weak self] in
      await tunnel.configure(config)
      guard let self else { return }
      self.lastAttempt = [:]
      self.onTunnelConfigured?()
    }
  }

  public func reconcile(machines: [CloudMachine]) {
    let ids = Set(machines.map(\.deviceId))
    for deviceId in Set(connections.keys).union(known.keys) where !ids.contains(deviceId) {
      drop(deviceId: deviceId)
    }
    for machine in machines {
      if let existing = connections[machine.deviceId] {
        guard existing.publicKey != machine.publicKey else {
          known[machine.deviceId] = machine
          continue
        }
        drop(deviceId: machine.deviceId)
      }
      let previous = known[machine.deviceId]
      known[machine.deviceId] = machine
      guard probeTasks[machine.deviceId] == nil else { continue }
      let addressChanged = previous?.tunnel?.endpointId != machine.tunnel?.endpointId
      if !addressChanged, let last = lastAttempt[machine.deviceId],
        last.duration(to: .now) < reprobeInterval
      {
        continue
      }
      startProbe(machine.deviceId)
    }
  }

  private func startProbe(_ deviceId: String) {
    guard let machine = known[deviceId], machine.tunnel != nil else { return }
    retryTasks.removeValue(forKey: deviceId)?.cancel()
    lastAttempt[deviceId] = .now
    dialing.insert(deviceId)
    let rebuild = endpointRebuild
    let generation = UUID()
    connectionGenerations[deviceId] = generation
    let onDown: @Sendable () -> Void = { [weak self] in
      guard let self else { return }
      Task { @MainActor in self.handleDown(deviceId: deviceId, generation: generation) }
    }
    probeTasks[deviceId] = Task { [weak self, prober] in
      await rebuild?.value
      let pipe = await prober(machine, onDown)
      guard let self, !Task.isCancelled, self.connectionGenerations[deviceId] == generation else {
        await pipe?.connection.shutdown()
        return
      }
      self.probeTasks[deviceId] = nil
      self.dialing.remove(deviceId)
      guard let pipe else {
        self.dialFailed(deviceId)
        return
      }
      let connection = pipe.connection
      guard self.connections[deviceId] == nil else {
        await connection.shutdown()
        return
      }
      self.resetFailures(deviceId)
      self.rebuiltSinceLastPipe = false
      self.connections[deviceId] = (connection, machine.publicKey)
      self.machineIds.insert(deviceId)
      self.pathReaders[deviceId] = pipe.path
      self.refreshPaths()
      self.startPathRefresh()
      self.resumeWaiters(deviceId)
      Log.cloud.log("Tunnel to machine \(deviceId, privacy: .public) is up")
      self.onPipeUp?(deviceId)
    }
  }

  private func dialFailed(_ deviceId: String) {
    if connections.isEmpty, !redialedForStreak.contains(deviceId) {
      redialedForStreak.insert(deviceId)
      if !rebuiltSinceLastPipe {
        rebuiltSinceLastPipe = true
        Log.cloud.notice(
          "Tunnel to machine \(deviceId, privacy: .public) failed with no pipe up; rebuilding the endpoint")
        let rebuildEndpoint = rebuildEndpoint
        endpointRebuild = Task { await rebuildEndpoint() }
      }
      startProbe(deviceId)
      return
    }
    scheduleRetry(deviceId)
  }

  private func resetFailures(_ deviceId: String) {
    failures[deviceId] = nil
    redialedForStreak.remove(deviceId)
  }

  private func scheduleRetry(_ deviceId: String) {
    let streak = (failures[deviceId] ?? 0) + 1
    failures[deviceId] = streak
    let delay = min(reprobeInterval * (1 << min(streak - 1, 4)), .seconds(600))
    let sleep = sleep
    retryTasks[deviceId]?.cancel()
    retryTasks[deviceId] = Task { [weak self] in
      guard (try? await sleep(delay)) != nil, let self, !Task.isCancelled else { return }
      self.retryTasks[deviceId] = nil
      guard self.connections[deviceId] == nil, self.probeTasks[deviceId] == nil else { return }
      self.startProbe(deviceId)
    }
  }

  private func handleDown(deviceId: String, generation: UUID) {
    guard connectionGenerations[deviceId] == generation,
      let entry = connections.removeValue(forKey: deviceId)
    else { return }
    connectionGenerations[deviceId] = nil
    Task { await entry.connection.shutdown() }
    machineIds.remove(deviceId)
    forgetPath(deviceId)
    lastReachable[deviceId] = Date()
    Log.cloud.log("Tunnel to machine \(deviceId, privacy: .public) went down")
    resetFailures(deviceId)
    guard probeTasks[deviceId] == nil else { return }
    startProbe(deviceId)
  }

  public func networkChanged() {
    let tunnel = tunnel
    Task { await tunnel.networkChanged() }
    rebuiltSinceLastPipe = false
    for deviceId in known.keys.sorted() {
      discardPipe(deviceId)
      startProbe(deviceId)
    }
  }

  public func setAllowsDirectPaths(_ allowed: Bool) {
    guard allowed != allowsDirectPaths else { return }
    allowsDirectPaths = allowed
    let tunnel = tunnel
    endpointRebuild = Task { await tunnel.setAllowsDirectPaths(allowed) }
    rebuiltSinceLastPipe = false
    for deviceId in known.keys.sorted() {
      discardPipe(deviceId)
      startProbe(deviceId)
    }
  }

  public func transport(for deviceId: String, publicKey: String) -> (any CloudChannelTransport)? {
    guard let entry = connections[deviceId], entry.publicKey == publicKey else { return nil }
    return CloudDirectTransport(connection: entry.connection)
  }

  public func awaitTransport(
    for deviceId: String,
    publicKey: String,
    machine: CloudMachine? = nil,
    timeout: Duration = .seconds(15)
  ) async throws -> any CloudChannelTransport {
    if let transport = transport(for: deviceId, publicKey: publicKey) { return transport }
    if known[deviceId] == nil, let machine, machine.deviceId == deviceId {
      known[deviceId] = machine
    }
    if probeTasks[deviceId] == nil { startProbe(deviceId) }
    let id = UUID()
    let sleep = sleep
    let timer = Task { [weak self] in
      guard (try? await sleep(timeout)) != nil else { return }
      self?.resumeWaiter(deviceId, id)
    }
    await withCheckedContinuation { continuation in
      waiters[deviceId, default: [:]][id] = continuation
    }
    timer.cancel()
    if let transport = transport(for: deviceId, publicKey: publicKey) { return transport }
    throw CloudTunnelUnavailableError(
      machineDeviceId: deviceId,
      hasTunnel: known[deviceId]?.tunnel != nil
    )
  }

  private func resumeWaiters(_ deviceId: String) {
    for continuation in (waiters.removeValue(forKey: deviceId) ?? [:]).values {
      continuation.resume()
    }
  }

  private func resumeWaiter(_ deviceId: String, _ id: UUID) {
    waiters[deviceId]?.removeValue(forKey: id)?.resume()
  }

  public func drop(deviceId: String) {
    discardPipe(deviceId)
    known[deviceId] = nil
    resumeWaiters(deviceId)
  }

  private func discardPipe(_ deviceId: String) {
    connectionGenerations[deviceId] = nil
    probeTasks.removeValue(forKey: deviceId)?.cancel()
    retryTasks.removeValue(forKey: deviceId)?.cancel()
    resetFailures(deviceId)
    machineIds.remove(deviceId)
    dialing.remove(deviceId)
    forgetPath(deviceId)
    guard let entry = connections.removeValue(forKey: deviceId) else { return }
    Task { await entry.connection.shutdown() }
  }

  func refreshPaths() {
    for (deviceId, read) in pathReaders {
      let path = read()
      if paths[deviceId] != path { paths[deviceId] = path }
    }
  }

  private func startPathRefresh() {
    guard pathRefresh == nil else { return }
    let sleep = sleep
    pathRefresh = Task { [weak self] in
      while (try? await sleep(Self.pathRefreshInterval)) != nil {
        guard let self, !Task.isCancelled else { return }
        self.refreshPaths()
        if self.pathReaders.isEmpty {
          self.pathRefresh = nil
          return
        }
      }
    }
  }

  private func forgetPath(_ deviceId: String) {
    pathReaders[deviceId] = nil
    paths[deviceId] = nil
  }

  public func dropAll() {
    for deviceId in Set(connections.keys).union(probeTasks.keys).union(known.keys) {
      drop(deviceId: deviceId)
    }
    lastAttempt = [:]
    rebuiltSinceLastPipe = false
  }
}

public struct CloudTunnelUnavailableError: LocalizedError, Equatable {
  public let machineDeviceId: String
  public let hasTunnel: Bool

  public var errorDescription: String? {
    hasTunnel
      ? "Check that it's online and connected to the internet."
      : "This machine's Codevisor is too old to connect. Update Codevisor on it."
  }
}

extension CloudDirectPathController {
  static func defaultProber(
    credentialStore: any CloudCredentialStore,
    tunnel: CloudTunnelEndpoint
  ) -> Prober {
    { machine, onDown in
      guard let address = machine.tunnel else { return nil }
      let transport = CloudTunnelWebSocketTransport(endpoint: tunnel, address: address)
      let connection = CloudDirectConnection(
        directURL: URL(string: "tunnel://\(machine.deviceId)")!,
        machineDeviceId: machine.deviceId,
        machinePublicKey: machine.publicKey,
        credentialStore: credentialStore,
        webSocketTransport: transport,
        readyTimeout: .seconds(15),
        onDown: onDown
      )
      let paths = transport.paths
      if await Self.verifySealedRoundTrip(connection) { return Pipe(connection: connection) { paths.current() } }
      Log.cloud.notice("Tunnel to machine \(machine.deviceId, privacy: .public) did not verify")
      await connection.shutdown()
      return nil
    }
  }

  static func verifySealedRoundTrip(_ connection: CloudDirectConnection) async -> Bool {
    let http = CloudRelayRequestTransport(
      endpoint: CloudDirectTransport(connection: connection),
      timeout: .seconds(6)
    )
    guard let url = URL(string: "http://machine.invalid/v1/info") else { return false }
    return (try? await http.data(for: URLRequest(url: url))) != nil
  }
}
