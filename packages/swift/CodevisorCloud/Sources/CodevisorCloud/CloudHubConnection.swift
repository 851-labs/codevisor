import CodevisorClient
import Foundation

// MARK: - Hub connection

/// The app's one WebSocket to its Codevisor Cloud hub — the control plane:
/// hello/welcome handshake, presence, the tunnel config (relay map and
/// rollout), and keepalive. Machine traffic never rides this socket; it goes
/// peer-to-peer over the tunnel (`CloudDirectPathController`).
///
/// Reconnects with jittered exponential backoff; hub close codes 4200/4201
/// are fatal (revoked token / unsupported protocol) and stop the loop.
public actor CloudHubConnection {
  public static let protocolVersion = 2
  static let maximumMessageSize = 16 * 1024 * 1024
  static let fatalCloseCodes: Set<Int> = [4200, 4201]

  private let serverURL: URL
  private let credentialStore: any CloudCredentialStore
  private let webSocketTransport: any ServerWebSocketTransport
  let deviceName: String
  let deviceOS: String
  let appVersion: String?
  let releaseChannel: CloudReleaseChannel
  let sleep: @Sendable (Duration) async throws -> Void
  private let reconnectDelay: @Sendable (Int) -> Duration
  private let readyTimeout: Duration
  private let heartbeatInterval: Duration
  let heartbeatTimeout: Duration
  let decoder = JSONDecoder()
  let encoder = JSONEncoder()

  private var runTask: Task<Void, Never>?
  var socket: (any ServerWebSocketConnecting)?
  var socketID: UUID?
  var isWelcomed = false
  var heartbeatTimeoutTask: Task<Void, Never>?
  var awaitingPongOnSocketID: UUID?
  private var fatalFailure: CloudHubConnectionError?
  private var waiterSeq = 0
  var readyWaiters: [Int: CheckedContinuation<Void, any Error>] = [:]
  /// Keychain-backed values are immutable for this hub's lifetime. The
  /// account controller destroys the hub on sign-out/server switch, so no
  /// reconnect should ever return to the credential store.
  private var cachedSessionToken: Result<String, CloudHubConnectionError>?
  private var cachedIdentity: Result<CloudAppDeviceIdentity, CloudHubConnectionError>?
  /// Serializes outbound socket writes so messages hit the wire in the order
  /// they were sent, even when several tasks send concurrently.
  var sendChain: Task<Void, Never> = Task {}
  /// Session resume: the token from the last welcome (offered in the next
  /// hello) and the connection identity it names.
  var resumeToken: String?
  var lastConnectionId: String?
  /// The machine presence list from welcome, kept fresh by presence frames.
  public internal(set) var machines: [CloudMachine] = []
  /// Fired after the transport's machine list changes from a hub frame —
  /// the welcome roster or a presence transition — with the full list. The
  /// account layer compares it against the UI roster and refreshes from
  /// REST on disagreement: this is what makes a machine signed in on
  /// another device appear in the UI in realtime, instead of waiting for
  /// the next foreground or a settings screen's poll.
  var machinesChangedHandler: (@Sendable ([CloudMachine]) -> Void)?
  /// Fired on every welcome with the instance's tunnel relay map and rollout;
  /// the latest is replayed to a handler installed after the welcome.
  var tunnelConfigHandler: (@Sendable (CloudTunnelConfig) -> Void)?
  var lastTunnelConfig: CloudTunnelConfig?

  /// Installs the presence observer (actor-isolated setter for the field
  /// above; the handler is invoked from the actor and must hop itself).
  public func setMachinesChangedHandler(
    _ handler: (@Sendable ([CloudMachine]) -> Void)?
  ) {
    machinesChangedHandler = handler
  }

  /// Installs the tunnel config observer (fired on every welcome). A welcome
  /// that already arrived is replayed, so installing late never misses it.
  public func setTunnelConfigHandler(_ handler: (@Sendable (CloudTunnelConfig) -> Void)?) {
    tunnelConfigHandler = handler
    if let lastTunnelConfig { handler?(lastTunnelConfig) }
  }

  public init(
    serverURL: URL,
    credentialStore: any CloudCredentialStore,
    deviceName: String = CloudHubConnection.defaultDeviceName,
    deviceOS: String = CloudHubConnection.defaultDeviceOS,
    appVersion: String? = nil,
    releaseChannel: CloudReleaseChannel = .shared,
    webSocketTransport: any ServerWebSocketTransport = URLSessionWebSocketTransport(),
    readyTimeout: Duration = .seconds(15),
    heartbeatInterval: Duration = .seconds(30),
    heartbeatTimeout: Duration = .seconds(10),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    reconnectDelay: @escaping @Sendable (Int) -> Duration = { failures in
      .milliseconds(min(5_000, 250 * (1 << min(failures, 5))) + Int.random(in: 0...250))
    }
  ) {
    self.sleep = sleep
    self.reconnectDelay = reconnectDelay
    self.serverURL = serverURL
    self.credentialStore = credentialStore
    self.deviceName = deviceName
    self.deviceOS = deviceOS
    self.appVersion = appVersion
    self.releaseChannel = releaseChannel
    self.webSocketTransport = webSocketTransport
    self.readyTimeout = readyTimeout
    self.heartbeatInterval = heartbeatInterval
    self.heartbeatTimeout = heartbeatTimeout
  }

  public static var defaultDeviceName: String {
    #if os(macOS)
      Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #else
      ProcessInfo.processInfo.hostName
    #endif
  }

  public static var defaultDeviceOS: String {
    #if os(macOS)
      "macOS"
    #elseif os(iOS)
      "iOS"
    #else
      "unknown"
    #endif
  }

  // MARK: Lifecycle

  /// Starts the connection loop if it isn't already running. Safe to call
  /// repeatedly.
  public func connect() {
    guard runTask == nil, fatalFailure == nil else { return }
    runTask = Task { await run() }
  }

  /// Tears everything down (sign-out / server switch). The instance is done
  /// after this — a new sign-in builds a new connection.
  public func shutdown() {
    runTask?.cancel()
    runTask = nil
    resumeToken = nil
    lastConnectionId = nil
    resetHeartbeat()
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    socketID = nil
    isWelcomed = false
    failWaiters(with: CloudHubConnectionError.disconnected)
  }

  /// Replaces the live socket without discarding account credentials. App
  /// lifecycle recovery uses this after returning to the foreground, when
  /// the old socket may be half-open after a suspension or network handoff.
  public func reconnect() {
    guard fatalFailure == nil else { return }
    guard let socket else {
      connect()
      return
    }
    Log.cloud.info("Replacing the cloud hub connection")
    isWelcomed = false
    resetHeartbeat()
    socket.cancel(with: .goingAway, reason: nil)
  }

  /// Waits until the hub has welcomed this connection (bounded by the ready
  /// timeout), starting the loop if needed.
  public func waitUntilReady() async throws {
    connect()
    if isWelcomed { return }
    if let fatalFailure { throw fatalFailure }
    let id = waiterSeq
    waiterSeq += 1
    let timeout = readyTimeout
    let sleep = sleep
    let timeoutTask = Task { [weak self] in
      try? await sleep(timeout)
      await self?.expireWaiter(id: id)
    }
    defer { timeoutTask.cancel() }
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        readyWaiters[id] = continuation
      }
    } onCancel: {
      Task { await self.cancelReadyWaiter(id) }
    }
  }

  private func cancelReadyWaiter(_ id: Int) {
    readyWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  private func expireWaiter(id: Int) {
    readyWaiters.removeValue(forKey: id)?
      .resume(throwing: CloudHubConnectionError.timedOut)
  }

  private func run() async {
    var failures = 0
    while !Task.isCancelled, fatalFailure == nil {
      do {
        let token = try sessionToken()
        let identity = try appDeviceIdentity()
        let request = Self.connectRequest(url: try connectURL(token: token), identity: identity)
        Log.cloud.info("Connecting to cloud hub at \(self.serverURL.host() ?? "?", privacy: .public)")
        let socket = webSocketTransport.connect(
          request,
          maximumMessageSize: Self.maximumMessageSize
        )
        let socketID = UUID()
        self.socket = socket
        self.socketID = socketID
        sendChain = Task {}
        try sendHello(identity: identity)
        // Keepalive: Cloudflare's edge (and local workerd) closes
        // idle WebSockets after ~100s, and URLSessionWebSocketTask
        // sends nothing on its own — so an app that sat idle would
        // find a dead hub the moment the user picks a machine.
        // Protocol pings are answered by the hub's auto-response
        // without even waking the Durable Object.
        let keepalive = Task { [weak self] in
          while !Task.isCancelled {
            guard let self else { return }
            try? await self.sleep(self.heartbeatInterval)
            guard !Task.isCancelled else { return }
            await self.sendKeepalivePing(on: socketID)
          }
        }
        defer { keepalive.cancel() }
        while !Task.isCancelled {
          let message = try await socket.receive()
          handle(message)
          if isWelcomed { failures = 0 }
        }
      } catch let error as CloudHubConnectionError where error == .notSignedIn {
        // No session: reconnecting cannot repair it. Signing in creates a
        // fresh instance.
        becomeFatal(error)
      } catch let error as CloudHubConnectionError where error == .credentialsUnavailable {
        // A Keychain read or write that failed (locked device, a transient
        // error). Nothing was cached, so the backoff below retries it; a
        // permanent failure here would leave every machine unreachable
        // until the app relaunched.
        Log.cloud.error("Cloud hub credentials unavailable; retrying")
      } catch {
        if !Task.isCancelled {
          Log.cloud.error("Cloud hub connection failed: \(String(describing: error), privacy: .public)")
        }
      }
      let closeCode = socket?.closeCode.rawValue ?? 0
      resetHeartbeat()
      socket?.cancel(with: .goingAway, reason: nil)
      socket = nil
      socketID = nil
      isWelcomed = false
      if Self.fatalCloseCodes.contains(closeCode) {
        becomeFatal(.rejected(closeCode: closeCode))
      }
      guard fatalFailure == nil, !Task.isCancelled else { break }
      failures += 1
      // Same curve as the other sockets: 250ms · 2^n capped at 5s + jitter.
      try? await sleep(reconnectDelay(failures))
    }
  }

  private func becomeFatal(_ failure: CloudHubConnectionError) {
    guard fatalFailure == nil else { return }
    Log.cloud.error("Cloud hub connection is fatal: \(String(describing: failure), privacy: .public)")
    fatalFailure = failure
    failWaiters(with: failure)
  }

  private func failWaiters(with error: any Error) {
    let waiters = readyWaiters.values
    readyWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(throwing: error)
    }
  }

  private func sessionToken() throws -> String {
    if let cachedSessionToken { return try cachedSessionToken.get() }
    let result: Result<String, CloudHubConnectionError>
    do {
      if let token = try credentialStore.token(), !token.isEmpty {
        result = .success(token)
      } else {
        result = .failure(.notSignedIn)
      }
    } catch {
      Log.cloud.error("Cloud session credential load failed: \(String(describing: error), privacy: .public)")
      // Not cached: a Keychain failure may be transient, so the next
      // reconnect reads again.
      throw CloudHubConnectionError.credentialsUnavailable
    }
    cachedSessionToken = result
    return try result.get()
  }

  private func appDeviceIdentity() throws -> CloudAppDeviceIdentity {
    if let cachedIdentity { return try cachedIdentity.get() }
    do {
      let identity = try credentialStore.ensureAppDeviceIdentity()
      cachedIdentity = .success(identity)
      return identity
    } catch {
      Log.cloud.error("Cloud device credential load failed: \(String(describing: error), privacy: .public)")
      // Not cached: a Keychain failure may be transient, so the next
      // reconnect reads again.
      throw CloudHubConnectionError.credentialsUnavailable
    }
  }

  /// RFC 3986 unreserved characters — everything else in the token is
  /// percent-encoded so it survives the hub's WHATWG query parsing.
  private static let tokenQueryAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  )

  private func connectURL(token: String) throws -> URL {
    guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
      throw CloudHubConnectionError.disconnected
    }
    components.scheme = components.scheme == "http" ? "ws" : "wss"
    let basePath =
      components.path.hasSuffix("/")
      ? String(components.path.dropLast())
      : components.path
    components.path = "\(basePath)/connect"
    // URLComponents.queryItems leaves "+" (and "/", "=") literal, but the
    // hub reads the query per the WHATWG URL standard, where "+" decodes
    // to a space. A session token containing "+" arrived corrupted, the
    // bearer lookup failed, and the connection either got rejected or —
    // worse — fell back to a stale session cookie in the shared cookie
    // jar and joined the wrong account's hub. Encode strictly so the
    // token round-trips verbatim.
    guard let encoded = token.addingPercentEncoding(withAllowedCharacters: Self.tokenQueryAllowed) else {
      throw CloudHubConnectionError.disconnected
    }
    components.percentEncodedQueryItems = [URLQueryItem(name: "token", value: encoded)]
    guard let url = components.url else { throw CloudHubConnectionError.disconnected }
    return url
  }
}
