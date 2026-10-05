import CodevisorClient
import Foundation
import Observation

/// Keeps one tunnel pipe per account machine (docs/plans/codevisor-tunnel.md):
/// dialed by the machine's key, direct when the network allows and through
/// our relays when it doesn't. The tunnel is the app's only data path to its
/// machines; the cloud hub only introduces devices (presence, addresses).
///
/// After each machine refresh the account controller hands over the online
/// machines whose keys match their TOFU pins. Each one with a tunnel address
/// gets a pipe that survives a sealed round trip (a welcome only proves
/// something is listening; the round trip proves it holds the pinned key).
/// Pipes repair themselves: a pipe that drops re-dials immediately, and a
/// failed dial retries with backoff, without waiting for a roster refresh.
/// When dials fail with no pipe up at all, the endpoint itself is suspect
/// (iOS can reclaim a suspended app's sockets without iroh noticing): it is
/// rebuilt — once until a pipe comes up or the network changes again — and
/// the machine re-dialed at once, once per failure streak.
@MainActor
@Observable
public final class CloudDirectPathController {
  /// A verified pipe, and how to read its current network path.
  public struct Pipe: Sendable {
    public let connection: CloudDirectConnection
    public let path: @Sendable () -> CloudTunnelPath?

    public init(connection: CloudDirectConnection, path: @escaping @Sendable () -> CloudTunnelPath? = { nil }) {
      self.connection = connection
      self.path = path
    }
  }

  /// Dials and verifies one machine's pipe (nil when it doesn't answer).
  /// Injectable so tests can script the dial. The second argument is the
  /// pipe's `onDown` callback.
  public typealias Prober =
    @Sendable (
      CloudMachine,
      @escaping @Sendable () -> Void
    ) async -> Pipe?

  /// Machines currently reachable over a verified pipe.
  public private(set) var machineIds: Set<String> = []
  /// Each live pipe's path (peer-to-peer or relayed, and its round trip), refreshed every
  /// `pathRefreshInterval` while any pipe is up.
  public private(set) var paths: [String: CloudTunnelPath] = [:]
  /// Machines being dialed right now.
  public private(set) var dialing: Set<String> = []
  /// When each machine's pipe last went down: "last seen" from this device's point of view.
  public private(set) var lastReachable: [String: Date] = [:]
  @ObservationIgnored private var pathReaders: [String: @Sendable () -> CloudTunnelPath?] = [:]
  @ObservationIgnored var pathRefresh: Task<Void, Never>?
  static let pathRefreshInterval: Duration = .seconds(5)

  @ObservationIgnored private var connections: [String: (connection: CloudDirectConnection, publicKey: String)] = [:]
  @ObservationIgnored private var connectionGenerations: [String: UUID] = [:]
  @ObservationIgnored var probeTasks: [String: Task<Void, Never>] = [:]
  /// Pending retries after failed dials, and each machine's failure streak
  /// (the retry backs off from `reprobeInterval` up to 10 minutes).
  @ObservationIgnored var retryTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var failures: [String: Int] = [:]
  /// Machines whose current failure streak already had its immediate
  /// re-dial on a rebuilt endpoint.
  @ObservationIgnored private var redialedForStreak: Set<String> = []
  /// Whether the endpoint was rebuilt and nothing has come up on it since:
  /// rebuilding again wouldn't help (every machine is unreachable, or the
  /// network is down), so failures just back off.
  @ObservationIgnored private var rebuiltSinceLastPipe = false
  /// The latest endpoint rebuild; dials wait for it before dialing.
  @ObservationIgnored private var endpointRebuild: Task<Void, Never>?
  @ObservationIgnored private var lastAttempt: [String: ContinuousClock.Instant] = [:]
  /// The latest reconciled machines, so a dropped or failed pipe re-dials on
  /// its own instead of waiting for the next roster refresh.
  @ObservationIgnored private var known: [String: CloudMachine] = [:]
  /// Channel opens waiting for a machine's pipe to come up.
  @ObservationIgnored private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
  private let prober: Prober
  private let rebuildEndpoint: @Sendable () async -> Void
  private let reprobeInterval: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  /// The app's tunnel endpoint, configured from each hub welcome.
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

  /// Fired (on the main actor) once a tunnel config has been applied, so the
  /// owner can re-dial machines whose earlier dial ran before the tunnel
  /// endpoint existed.
  @ObservationIgnored public var onTunnelConfigured: (@MainActor () -> Void)?

  /// Fired (on the main actor) with a machine's device id whenever its pipe
  /// comes up, so whoever tracks the machine's availability can stop
  /// waiting out a retry backoff and use it now.
  @ObservationIgnored public var onPipeUp: (@MainActor (String) -> Void)?

  /// Applies a hub welcome's tunnel config (relay map), then lifts the
  /// re-dial throttle so the next reconcile dials again.
  public func configureTunnel(_ config: CloudTunnelConfig) {
    let tunnel = tunnel
    Task { [weak self] in
      await tunnel.configure(config)
      guard let self else { return }
      self.lastAttempt = [:]
      self.onTunnelConfigured?()
    }
  }

  /// Reconciles the pipes against the current (verified-key, online)
  /// machine list: gone machines lose their pipe, machines without one get
  /// a throttled dial.
  public func reconcile(machines: [CloudMachine]) {
    let ids = Set(machines.map(\.deviceId))
    for deviceId in Set(connections.keys).union(known.keys) where !ids.contains(deviceId) {
      drop(deviceId: deviceId)
    }
    for machine in machines {
      if let existing = connections[machine.deviceId] {
        // A re-provisioned machine (fresh keys, same device id) needs a
        // fresh pipe — the old one seals toward the old key.
        guard existing.publicKey != machine.publicKey else {
          known[machine.deviceId] = machine
          continue
        }
        drop(deviceId: machine.deviceId)
      }
      let previous = known[machine.deviceId]
      known[machine.deviceId] = machine
      guard probeTasks[machine.deviceId] == nil else { continue }
      // A tunnel address that just appeared (the cached roster at launch
      // has none) is fresh information: dial now.
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
    // No tunnel address yet (the machine's server predates the tunnel, or
    // its presence hasn't arrived): nothing to dial until the roster says.
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
      // Never dial the endpoint a rebuild is replacing.
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

  /// A failed dial. With no pipe up at all, the endpoint is the likelier
  /// culprit than the machine: rebuild it (unless that was already tried
  /// since the last pipe came up) and dial again right away, once per
  /// failure streak. Otherwise back off.
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

  /// A failed dial retries on its own, backing off from `reprobeInterval`.
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
    // The pipe dying is fresh information (the network changed): re-dial
    // now rather than on the next roster refresh.
    resetFailures(deviceId)
    guard probeTasks[deviceId] == nil else { return }
    startProbe(deviceId)
  }

  /// The network may have changed under every pipe: the app is back from
  /// suspension, or the OS reported a new path. Tells the endpoint, then
  /// replaces every pipe and in-flight dial with a fresh dial, skipping any
  /// backoff. A pipe that survived suspension half-open would otherwise
  /// stall requests until its heartbeat noticed.
  ///
  /// Unlike `dropAll`, the machines stay known: the re-dial must not wait
  /// for a roster refresh, which can fail on the same bad network.
  public func networkChanged() {
    let tunnel = tunnel
    Task { await tunnel.networkChanged() }
    // A new network is a new chance for a rebuild to help.
    rebuiltSinceLastPipe = false
    for deviceId in known.keys.sorted() {
      discardPipe(deviceId)
      startProbe(deviceId)
    }
  }

  /// The pipe for a machine, iff it seals toward exactly the given
  /// (verified) key. nil = no pipe right now.
  public func transport(for deviceId: String, publicKey: String) -> (any CloudChannelTransport)? {
    guard let entry = connections[deviceId], entry.publicKey == publicKey else { return nil }
    return CloudDirectTransport(connection: entry.connection)
  }

  /// The pipe for a machine, waiting up to `timeout` for one that is still
  /// being dialed (app launch, a network change). Throws when the machine
  /// stays unreachable.
  ///
  /// `machine` is the caller's view of the machine, used to dial it when
  /// the controller doesn't know it yet (after `dropAll`, before the
  /// roster refresh that would reconcile it).
  public func awaitTransport(
    for deviceId: String,
    publicKey: String,
    machine: CloudMachine? = nil,
    timeout: Duration = .seconds(15)
  ) async throws -> any CloudChannelTransport {
    if let transport = transport(for: deviceId, publicKey: publicKey) { return transport }
    // Someone is waiting on this machine right now: dial unless a dial is
    // already in flight, rather than wait out a backoff or a roster refresh.
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

  /// Silently tears down one machine's pipe and forgets it (removal, key
  /// change).
  public func drop(deviceId: String) {
    discardPipe(deviceId)
    known[deviceId] = nil
    resumeWaiters(deviceId)
  }

  /// Silently ends a machine's pipe, dial and pending retry, and its
  /// failure streak. The machine stays known.
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

  /// Reads every live pipe's path; only changes are published.
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

  /// Sign-out / server switch: everything goes.
  public func dropAll() {
    for deviceId in Set(connections.keys).union(probeTasks.keys).union(known.keys) {
      drop(deviceId: deviceId)
    }
    lastAttempt = [:]
    rebuiltSinceLastPipe = false
  }
}

/// A machine the app could not reach over the tunnel.
public struct CloudTunnelUnavailableError: LocalizedError, Equatable {
  public let machineDeviceId: String
  /// False when the machine's server predates the tunnel.
  public let hasTunnel: Bool

  public var errorDescription: String? {
    hasTunnel
      ? "Check that it's online and connected to the internet."
      : "This machine's Codevisor is too old to connect. Update Codevisor on it."
  }
}

// MARK: - Default prober

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

  /// One sealed request over the candidate pipe. Success requires the far
  /// end to complete the channel key agreement with the pinned machine key,
  /// so an imposter endpoint fails here and the candidate is discarded.
  static func verifySealedRoundTrip(_ connection: CloudDirectConnection) async -> Bool {
    let http = CloudRelayRequestTransport(
      endpoint: CloudDirectTransport(connection: connection),
      timeout: .seconds(6)
    )
    guard let url = URL(string: "http://machine.invalid/v1/info") else { return false }
    return (try? await http.data(for: URLRequest(url: url))) != nil
  }
}
