import CodevisorClient
import Foundation

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
  private var cachedSessionToken: Result<String, CloudHubConnectionError>?
  private var cachedIdentity: Result<CloudAppDeviceIdentity, CloudHubConnectionError>?
  var sendChain: Task<Void, Never> = Task {}
  var resumeToken: String?
  var lastConnectionId: String?
  public internal(set) var machines: [CloudMachine] = []
  var machinesChangedHandler: (@Sendable ([CloudMachine]) -> Void)?
  var tunnelConfigHandler: (@Sendable (CloudTunnelConfig) -> Void)?
  var lastTunnelConfig: CloudTunnelConfig?

  public func setMachinesChangedHandler(
    _ handler: (@Sendable ([CloudMachine]) -> Void)?
  ) {
    machinesChangedHandler = handler
  }

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

  public func connect() {
    guard runTask == nil, fatalFailure == nil else { return }
    runTask = Task { await run() }
  }

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
        becomeFatal(error)
      } catch let error as CloudHubConnectionError where error == .credentialsUnavailable {
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
      throw CloudHubConnectionError.credentialsUnavailable
    }
  }

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
    guard let encoded = token.addingPercentEncoding(withAllowedCharacters: Self.tokenQueryAllowed) else {
      throw CloudHubConnectionError.disconnected
    }
    components.percentEncodedQueryItems = [URLQueryItem(name: "token", value: encoded)]
    guard let url = components.url else { throw CloudHubConnectionError.disconnected }
    return url
  }
}
