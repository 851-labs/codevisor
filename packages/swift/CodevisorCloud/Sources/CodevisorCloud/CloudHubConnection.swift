import ACPKit
import CodevisorClient
import Foundation

// MARK: - Hub connection

/// The app's one WebSocket to its Codevisor Cloud hub: hello/welcome handshake,
/// presence, and multiplexed end-to-end encrypted relay channels to machines.
/// The app is always the channel opener; per-direction sequence numbers start
/// at 0 and the responder direction is enforced monotonic here.
///
/// Reconnects with jittered exponential backoff; hub close codes 4200/4201
/// are fatal (revoked token / unsupported protocol) and stop the loop.
/// Channels are ephemeral: they die with either WebSocket and openers
/// re-establish what they need after reconnect.
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
  private let readyTimeout: Duration
  private let heartbeatInterval: Duration
  let heartbeatTimeout: Duration
  /// How long held channels survive a socket gap while a resume is pending
  /// before degrading to the plain teardown (slightly above the hub's
  /// 60s grace, so the hub — not a local timer — decides the outcome).
  let resumeSuspensionTimeout: Duration
  let decoder = JSONDecoder()
  let encoder = JSONEncoder()

  private var runTask: Task<Void, Never>?
  var socket: (any ServerWebSocketConnecting)?
  var socketID: UUID?
  var isWelcomed = false
  var heartbeatTimeoutTask: Task<Void, Never>?
  var awaitingPongOnSocketID: UUID?
  /// When the outstanding keepalive ping left, for RTT measurement.
  var pingSentAt: ContinuousClock.Instant?
  /// Relay round-trip time from the most recent keepalive ping/pong —
  /// path-latency observability, never used for routing decisions.
  public internal(set) var lastRttMillis: Int?
  private var fatalFailure: CloudHubConnectionError?
  private var waiterSeq = 0
  var readyWaiters: [Int: CheckedContinuation<Void, any Error>] = [:]
  private var machineWaiterSeq = 0
  private var machineOnlineWaiters: [Int: (machineId: String, continuation: CheckedContinuation<Void, any Error>)] =
    [:]
  var channels: [String: ChannelState] = [:]
  /// Keychain-backed values are immutable for this hub's lifetime. The
  /// account controller destroys the hub on sign-out/server switch, so no
  /// channel or reconnect should ever return to the credential store.
  private var cachedSessionToken: Result<String, CloudHubConnectionError>?
  private var cachedIdentity: Result<CloudAppDeviceIdentity, CloudHubConnectionError>?
  /// Serializes outbound socket writes so relay frames hit the wire in seq
  /// order even when several tasks send concurrently.
  var sendChain: Task<Void, Never> = Task {}
  /// Session resume: the token from the last welcome, the identity it
  /// names, and the deadline that bounds a suspension nobody resumes.
  var resumeToken: String?
  var lastConnectionId: String?
  var suspensionTask: Task<Void, Never>?
  /// The machine presence list from welcome, kept fresh by presence frames.
  public internal(set) var machines: [CloudMachine] = []
  /// Fired after the transport's machine list changes from a hub frame —
  /// the welcome roster or a presence transition — with the full list. The
  /// account layer compares it against the UI roster and refreshes from
  /// REST on disagreement: this is what makes a machine signed in on
  /// another device appear in the UI in realtime, instead of waiting for
  /// the next foreground or a settings screen's poll.
  var machinesChangedHandler: (@Sendable ([CloudMachine]) -> Void)?

  /// Installs the presence observer (actor-isolated setter for the field
  /// above; the handler is invoked from the actor and must hop itself).
  public func setMachinesChangedHandler(
    _ handler: (@Sendable ([CloudMachine]) -> Void)?
  ) {
    machinesChangedHandler = handler
  }

  final class ChannelState {
    let machineDeviceId: String
    let cipher: CloudChannelCipher
    var nextOutboundSeq: UInt64
    var nextInboundSeq: UInt64 = 0
    let flowControlled: Bool
    /// Negotiated prefix-framed payloads: every data plaintext in both
    /// directions starts with a framing byte and the machine may DEFLATE
    /// bodies it deems worthwhile (see CloudDeflate).
    let compressed: Bool
    var inboundCredit = 0
    let onMessage: @Sendable (Data, Int) -> Void
    let onCredit: @Sendable (Int) -> Void
    let onClosed: @Sendable (CloudChannelCloseReason?) -> Void

    init(
      machineDeviceId: String,
      cipher: CloudChannelCipher,
      nextOutboundSeq: UInt64,
      flowControlled: Bool,
      compressed: Bool,
      onMessage: @escaping @Sendable (Data, Int) -> Void,
      onCredit: @escaping @Sendable (Int) -> Void,
      onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) {
      self.machineDeviceId = machineDeviceId
      self.cipher = cipher
      self.nextOutboundSeq = nextOutboundSeq
      self.flowControlled = flowControlled
      self.compressed = compressed
      self.onMessage = onMessage
      self.onCredit = onCredit
      self.onClosed = onClosed
    }
  }

  public init(
    serverURL: URL,
    credentialStore: any CloudCredentialStore,
    deviceName: String = CloudHubConnection.defaultDeviceName,
    deviceOS: String = CloudHubConnection.defaultDeviceOS,
    appVersion: String? = nil,
    webSocketTransport: any ServerWebSocketTransport = URLSessionWebSocketTransport(),
    readyTimeout: Duration = .seconds(15),
    heartbeatInterval: Duration = .seconds(30),
    heartbeatTimeout: Duration = .seconds(10),
    resumeSuspensionTimeout: Duration = .seconds(70)
  ) {
    self.serverURL = serverURL
    self.credentialStore = credentialStore
    self.deviceName = deviceName
    self.deviceOS = deviceOS
    self.appVersion = appVersion
    self.webSocketTransport = webSocketTransport
    self.readyTimeout = readyTimeout
    self.heartbeatInterval = heartbeatInterval
    self.heartbeatTimeout = heartbeatTimeout
    self.resumeSuspensionTimeout = resumeSuspensionTimeout
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
    suspensionTask?.cancel()
    suspensionTask = nil
    resumeToken = nil
    lastConnectionId = nil
    resetHeartbeat()
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    socketID = nil
    isWelcomed = false
    failAllChannels()
    failWaiters(with: CloudHubConnectionError.disconnected)
    failMachineWaiters(with: CloudHubConnectionError.disconnected)
  }

  /// Replaces the live socket without discarding account credentials. App
  /// lifecycle recovery uses this after returning to the foreground: every
  /// relay channel is ephemeral, so its owner reconnects from its durable
  /// cursor on the newly welcomed socket.
  public func reconnect() {
    guard fatalFailure == nil else { return }
    guard let socket else {
      connect()
      return
    }
    Log.cloud.info("Replacing the cloud hub connection")
    isWelcomed = false
    resetHeartbeat()
    // Held channels ride through the replacement when the next welcome
    // resumes; the run loop's teardown decides their fate otherwise.
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
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      await self?.expireWaiter(id: id)
    }
    defer { timeoutTask.cancel() }
    try await withCheckedThrowingContinuation { continuation in
      readyWaiters[id] = continuation
    }
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
        var request = URLRequest(url: try connectURL(token: token))
        // The query token is the sole credential. Never let a stale
        // session cookie from the shared jar ride along — if the hub
        // honored it over the token, this device would silently join
        // the wrong account.
        request.httpShouldHandleCookies = false
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
            try? await Task.sleep(for: self.heartbeatInterval)
            guard !Task.isCancelled else { return }
            await self.sendKeepalivePing(on: socketID)
          }
        }
        defer { keepalive.cancel() }
        while !Task.isCancelled {
          let message = try await socket.receive()
          await handle(message)
          if isWelcomed { failures = 0 }
        }
      } catch let error as CloudHubConnectionError
        where error == .notSignedIn || error == .credentialsUnavailable
      {
        // Credential failures cannot be repaired by reconnecting this
        // hub. A sign-in/retry creates a fresh instance.
        becomeFatal(error)
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
      let fatal = Self.fatalCloseCodes.contains(closeCode)
      if fatal || resumeToken == nil {
        failAllChannels()
      } else {
        // Suspend: channels ride out the gap awaiting a resumed
        // welcome, bounded so nothing hangs if the hub forgets us.
        armSuspensionDeadline()
      }
      if fatal {
        becomeFatal(.rejected(closeCode: closeCode))
      }
      guard fatalFailure == nil, !Task.isCancelled else { break }
      failures += 1
      // Same curve as the other sockets: 250ms · 2^n capped at 5s + jitter.
      let base = min(5_000, 250 * (1 << min(failures, 5)))
      try? await Task.sleep(for: .milliseconds(base + Int.random(in: 0...250)))
    }
  }

  private func armSuspensionDeadline() {
    suspensionTask?.cancel()
    let timeout = resumeSuspensionTimeout
    suspensionTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      await self?.expireSuspension()
    }
  }

  private func expireSuspension() {
    guard !isWelcomed else { return }
    failAllChannels()
  }

  private func becomeFatal(_ failure: CloudHubConnectionError) {
    guard fatalFailure == nil else { return }
    Log.cloud.error("Cloud hub connection is fatal: \(String(describing: failure), privacy: .public)")
    fatalFailure = failure
    failWaiters(with: failure)
    failMachineWaiters(with: failure)
  }

  private func failWaiters(with error: any Error) {
    let waiters = readyWaiters.values
    readyWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(throwing: error)
    }
  }

  private func failMachineWaiters(with error: any Error) {
    let waiters = machineOnlineWaiters.values
    machineOnlineWaiters.removeAll()
    for waiter in waiters {
      waiter.continuation.resume(throwing: error)
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
      result = .failure(.credentialsUnavailable)
    }
    cachedSessionToken = result
    return try result.get()
  }

  func appDeviceIdentity() throws -> CloudAppDeviceIdentity {
    if let cachedIdentity { return try cachedIdentity.get() }
    let result: Result<CloudAppDeviceIdentity, CloudHubConnectionError>
    do {
      result = .success(try credentialStore.ensureAppDeviceIdentity())
    } catch {
      Log.cloud.error("Cloud device credential load failed: \(String(describing: error), privacy: .public)")
      result = .failure(.credentialsUnavailable)
    }
    cachedIdentity = result
    return try result.get()
  }

  /// An offline machine is a state transition, not a timer-based connection
  /// failure. Park channel openers until presence says it is back instead of
  /// letting every event stream and terminal create an independent retry
  /// loop. Cancellation removes the parked request promptly.
  func waitUntilMachineOnline(_ machineId: String) async throws {
    guard let machine = machines.first(where: { $0.deviceId == machineId }) else {
      throw CloudHubConnectionError.machineUnavailable
    }
    if machine.online { return }
    if Task.isCancelled { throw CancellationError() }

    let id = machineWaiterSeq
    machineWaiterSeq += 1
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let cancelled = withUnsafeCurrentTask { $0?.isCancelled ?? false }
        guard !cancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        machineOnlineWaiters[id] = (machineId, continuation)
      }
    } onCancel: {
      Task { await self.cancelMachineWaiter(id) }
    }
  }

  private func cancelMachineWaiter(_ id: Int) {
    machineOnlineWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
  }

  func resumeMachineWaiters(for machineId: String) {
    let ready = machineOnlineWaiters.filter { $0.value.machineId == machineId }
    for (id, waiter) in ready {
      machineOnlineWaiters.removeValue(forKey: id)
      waiter.continuation.resume()
    }
  }

  func failAllChannels() {
    let open = channels.values
    channels.removeAll()
    for channel in open {
      channel.onClosed(nil)
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
