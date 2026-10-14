import ACPKit
import CodevisorClient
import Foundation

public actor CloudDirectConnection: CloudChannelHosting {
  public static let protocolVersion = CloudHubConnection.protocolVersion
  static let maximumMessageSize = CloudHubConnection.maximumMessageSize

  public let machineDeviceId: String
  private let machinePublicKey: String
  private let directURL: URL
  private let credentialStore: any CloudCredentialStore
  private let deviceName: String
  private let deviceOS: String
  private let appVersion: String?
  private let webSocketTransport: any ServerWebSocketTransport
  private let sleep: @Sendable (Duration) async throws -> Void
  private let readyTimeout: Duration
  private let heartbeatInterval: Duration
  private let heartbeatTimeout: Duration
  private var onDown: (@Sendable () -> Void)?

  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private var runTask: Task<Void, Never>?
  private var socket: (any ServerWebSocketConnecting)?
  private var isWelcomed = false
  private var isDown = false
  private var waiterSeq = 0
  private var readyWaiters: [Int: CheckedContinuation<Void, any Error>] = [:]
  private var heartbeatTask: Task<Void, Never>?
  private var pongDeadlineTask: Task<Void, Never>?
  private var sendChain: Task<Void, Never> = Task {}
  private var channels: [String: CloudDirectChannelState] = [:]

  public init(
    directURL: URL,
    machineDeviceId: String,
    machinePublicKey: String,
    credentialStore: any CloudCredentialStore,
    deviceName: String = CloudHubConnection.defaultDeviceName,
    deviceOS: String = CloudHubConnection.defaultDeviceOS,
    appVersion: String? = nil,
    webSocketTransport: any ServerWebSocketTransport = URLSessionWebSocketTransport(),
    readyTimeout: Duration = .seconds(5),
    heartbeatInterval: Duration = .seconds(10),
    heartbeatTimeout: Duration = .seconds(5),
    onDown: (@Sendable () -> Void)? = nil,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.sleep = sleep
    self.directURL = directURL
    self.machineDeviceId = machineDeviceId
    self.machinePublicKey = machinePublicKey
    self.credentialStore = credentialStore
    self.deviceName = deviceName
    self.deviceOS = deviceOS
    self.appVersion = appVersion
    self.webSocketTransport = webSocketTransport
    self.readyTimeout = readyTimeout
    self.heartbeatInterval = heartbeatInterval
    self.heartbeatTimeout = heartbeatTimeout
    self.onDown = onDown
  }

  public func connect() {
    guard runTask == nil, !isDown else { return }
    runTask = Task { await run() }
  }

  public var isReady: Bool { isWelcomed && !isDown }

  public func shutdown() {
    onDown = nil
    runTask?.cancel()
    goDown()
  }

  public func waitUntilReady() async throws {
    guard !isDown else { throw CloudHubConnectionError.disconnected }
    connect()
    if isWelcomed { return }
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
    do {
      let identity = try credentialStore.ensureAppDeviceIdentity()
      var request = URLRequest(url: directURL)
      request.httpShouldHandleCookies = false
      let socket = webSocketTransport.connect(
        request,
        maximumMessageSize: Self.maximumMessageSize
      )
      self.socket = socket
      try sendHello(identity: identity)
      while !Task.isCancelled {
        let message = try await socket.receive()
        handle(message)
      }
    } catch {
      if !Task.isCancelled, !isDown {
        Log.cloud.notice(
          "Direct pipe to \(self.machineDeviceId, privacy: .public) ended: \(String(describing: error), privacy: .public)"
        )
      }
    }
    goDown()
  }

  private func goDown() {
    guard !isDown else { return }
    isDown = true
    heartbeatTask?.cancel()
    heartbeatTask = nil
    pongDeadlineTask?.cancel()
    pongDeadlineTask = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    isWelcomed = false
    let open = channels.values
    channels.removeAll()
    for channel in open {
      channel.onClosed(nil)
    }
    let waiters = readyWaiters.values
    readyWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(throwing: CloudHubConnectionError.disconnected)
    }
    onDown?()
    onDown = nil
  }

  private func sendHello(identity: CloudAppDeviceIdentity) throws {
    let hello = CloudDirectHelloMessage(
      device: CloudDirectHelloMessage.Device(
        deviceId: identity.deviceId,
        name: deviceName,
        os: deviceOS,
        appVersion: appVersion,
        publicKey: identity.publicKey
      ))
    try enqueueSend(.string(String(decoding: try encoder.encode(hello), as: UTF8.self)))
  }

  private func handle(_ message: ServerWebSocketMessage) {
    switch message {
    case let .data(payload):
      guard let envelopes = try? CloudRelayWire.decode(payload) else { return }
      for envelope in envelopes {
        guard let relay = try? decoder.decode(CloudDirectRelayHeader.self, from: envelope.header),
          relay.machineId == machineDeviceId
        else { continue }
        handleRelay(relay.frame, payload: envelope.payload)
      }
    case let .string(text):
      guard let probe = try? decoder.decode(CloudDirectTypeProbe.self, from: Data(text.utf8)) else {
        return
      }
      switch probe.t {
      case "welcome":
        isWelcomed = true
        startHeartbeat()
        let waiters = readyWaiters.values
        readyWaiters.removeAll()
        for waiter in waiters {
          waiter.resume()
        }
      case "pong":
        pongDeadlineTask?.cancel()
        pongDeadlineTask = nil
      default:
        break
      }
    }
  }

  private func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task { [weak self, heartbeatInterval] in
      while !Task.isCancelled {
        try? await self?.sleep(heartbeatInterval)
        guard !Task.isCancelled, let self else { return }
        await self.sendKeepalivePing()
      }
    }
  }

  private func sendKeepalivePing() {
    guard isWelcomed, !isDown, pongDeadlineTask == nil else { return }
    struct Ping: Encodable {
      var t = "ping"
    }
    pongDeadlineTask = Task { [weak self, heartbeatTimeout] in
      try? await self?.sleep(heartbeatTimeout)
      guard !Task.isCancelled else { return }
      await self?.expireHeartbeat()
    }
    do {
      try enqueueSend(.string(String(decoding: try encoder.encode(Ping()), as: UTF8.self)))
    } catch {
      goDown()
    }
  }

  private func expireHeartbeat() {
    guard !isDown, pongDeadlineTask != nil else { return }
    Log.cloud.notice(
      "Direct pipe to \(self.machineDeviceId, privacy: .public) missed its pong deadline")
    goDown()
  }

  func sendRelay(frame: CloudRelayFrame, payload: Data = Data()) throws {
    let header = try encoder.encode(CloudDirectRelayHeader(machineId: machineDeviceId, frame: frame))
    try enqueueSend(
      .data(CloudRelayWire.encode([CloudRelayEnvelope(header: header, payload: payload)])))
  }

  private func enqueueSend(_ message: ServerWebSocketMessage) throws {
    guard let socket, !isDown else { throw CloudHubConnectionError.disconnected }
    sendChain = Task { [weak self, previous = sendChain] in
      await previous.value
      do {
        try await socket.send(message)
      } catch {
        await self?.goDown()
      }
    }
  }

  private func handleRelay(_ frame: CloudRelayFrame, payload: Data) {
    guard let state = channels[frame.channelId] else { return }
    state.receivedInbound = true
    if case let .close(channelId, _, reason) = frame {
      channels.removeValue(forKey: channelId)
      state.onClosed(reason)
      return
    }
    guard frame.seq == state.nextInboundSeq else {
      abortChannel(frame.channelId, reason: .protocolError)
      return
    }
    state.nextInboundSeq += 1
    switch frame {
    case .open:
      abortChannel(frame.channelId, reason: .protocolError)
    case let .data(channelId, seq):
      if let reason = state.receiveData(payload, channelId: channelId, seq: seq) {
        abortChannel(channelId, reason: reason)
      }
    case let .credit(channelId, _, bytes):
      guard bytes > 0 else {
        abortChannel(channelId, reason: .protocolError)
        return
      }
      state.onCredit(bytes)
    case .close:
      break
    }
  }

  public func openChannel(
    channelType: String,
    params: JSONValue?,
    compressed: Bool = false,
    onMessage: @escaping @Sendable (Data) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel {
    try await openChannel(
      channelType: channelType,
      params: params,
      flowControlled: false,
      compressed: compressed,
      onMessage: { data, _ in onMessage(data) },
      onCredit: { _ in },
      onClosed: onClosed
    )
  }

  public func openFlowControlledChannel(
    channelType: String,
    params: JSONValue?,
    compressed: Bool = false,
    onMessage: @escaping @Sendable (Data, Int) -> Void,
    onCredit: @escaping @Sendable (Int) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel {
    try await openChannel(
      channelType: channelType,
      params: params,
      flowControlled: true,
      compressed: compressed,
      onMessage: onMessage,
      onCredit: onCredit,
      onClosed: onClosed
    )
  }

  private func openChannel(
    channelType: String,
    params: JSONValue?,
    flowControlled: Bool,
    compressed: Bool,
    onMessage: @escaping @Sendable (Data, Int) -> Void,
    onCredit: @escaping @Sendable (Int) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel {
    try await waitUntilReady()
    let identity = try credentialStore.ensureAppDeviceIdentity()
    let opened = try CloudChannelCrypto.openChannel(
      openerSecretKey: identity.secretKey,
      responderPublicKey: machinePublicKey
    )
    let channelId = UUID().uuidString.lowercased()
    var payload: [String: JSONValue] = ["channelType": .string(channelType)]
    if let params {
      payload["params"] = params
    }
    if compressed {
      payload["compress"] = .bool(true)
    }
    if flowControlled {
      payload["flowControl"] = .bool(true)
    }
    let plaintext = try encoder.encode(JSONValue.object(payload))
    let sealed = try opened.cipher.seal(
      plaintext,
      channelId: channelId,
      direction: .openerToResponder,
      seq: 0
    )
    let state = CloudDirectChannelState(
      cipher: opened.cipher,
      nextOutboundSeq: 1,
      flowControlled: flowControlled,
      compressed: compressed,
      onMessage: onMessage,
      onCredit: onCredit,
      onClosed: onClosed
    )
    channels[channelId] = state
    do {
      try sendRelay(
        frame: .open(channelId: channelId, seq: 0, ephemeralKey: opened.ephemeralPublicKey),
        payload: sealed
      )
    } catch {
      channels.removeValue(forKey: channelId)
      throw error
    }
    return CloudRelayChannel(id: channelId, host: self)
  }

  func send(channelId: String, plaintext: Data) throws -> Int {
    guard let state = channels[channelId] else {
      throw CloudHubConnectionError.channelClosed
    }
    guard isWelcomed, !isDown else { throw CloudHubConnectionError.disconnected }
    let sealed = try state.sealData(plaintext, channelId: channelId)
    try sendRelay(frame: sealed.frame, payload: sealed.payload)
    return sealed.payload.count
  }

  func grantCredit(channelId: String, bytes: Int) throws {
    guard let state = channels[channelId] else {
      throw CloudHubConnectionError.channelClosed
    }
    guard bytes > 0, state.inboundCredit <= Int.max - bytes else {
      abortChannel(channelId, reason: .protocolError)
      throw CloudHubConnectionError.channelClosed
    }
    guard isWelcomed, !isDown else { throw CloudHubConnectionError.disconnected }
    if state.flowControlled {
      state.inboundCredit += bytes
    }
    let seq = state.nextOutboundSeq
    state.nextOutboundSeq += 1
    try sendRelay(frame: .credit(channelId: channelId, seq: seq, bytes: bytes))
  }

  func closeChannel(_ channelId: String, reason: CloudChannelCloseReason) {
    guard let state = channels.removeValue(forKey: channelId) else { return }
    let seq = state.nextOutboundSeq
    state.nextOutboundSeq += 1
    try? sendRelay(frame: .close(channelId: channelId, seq: seq, reason: reason))
  }

  func reportUnanswered(channelId: String) {
    guard let state = channels[channelId], !state.receivedInbound, !isDown else { return }
    Log.cloud.notice(
      "Direct pipe to \(self.machineDeviceId, privacy: .public) left a channel open unanswered; falling back to the relay"
    )
    goDown()
  }

  private func abortChannel(_ channelId: String, reason: CloudChannelCloseReason) {
    guard let state = channels.removeValue(forKey: channelId) else { return }
    let seq = state.nextOutboundSeq
    state.nextOutboundSeq += 1
    try? sendRelay(frame: .close(channelId: channelId, seq: seq, reason: reason))
    state.onClosed(reason)
  }
}
