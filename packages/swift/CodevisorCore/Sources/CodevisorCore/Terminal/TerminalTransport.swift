import Foundation

public struct TerminalCreated: Decodable, Sendable {
  public var terminalId: String
  public var websocketPath: String
  public var nextOutputSeq: Int
}

public enum TerminalEvent: Sendable {
  case output(TerminalOutput, replayed: Bool)
  case exit(code: Int?)
  case error(String)
  case ptySize(cols: Int, rows: Int)
}

@MainActor
public final class TerminalTransport {
  public typealias EventHandler = @MainActor (TerminalEvent) -> Void

  private let config: CodevisorServerConfig
  private let requestTransport: any ServerRequestTransport
  private let webSocketTransport: any ServerWebSocketTransport
  private let onEvent: EventHandler
  private let sleep: @Sendable (Duration) async throws -> Void
  private let clientId = UUID().uuidString
  private var clientSeq = 0
  private var lastOutputSeq = 0
  private var liveOutputSeq = 0
  private var attachment: (sessionId: String, cwd: String)?
  private var replayedOutput: TerminalOutput?
  private var websocketPath: String?
  private var socket: (any ServerWebSocketConnecting)?
  private var inbound: TerminalInboundFrames?
  private var receiveTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var sendChain: Task<Void, Never> = Task {}
  private var failures = 0
  private var closed = false
  private var size: (cols: Int, rows: Int)?
  private var pendingInput: [(clientSeq: Int, data: String)] = []
  private var pendingInputBytes = 0
  static let pendingInputLimit = 64 * 1024
  public private(set) var roundTripTime: Duration?
  private var pingTask: Task<Void, Never>?
  private var serverSpeaksProtocol2 = false
  private var serverProtocolKnown = false
  private var unacknowledged: [(clientSeq: Int, text: String)] = []
  private var acknowledgedSeq = 0
  private var claimed = false
  private var claimSeq = Int.max
  private var unacknowledgedBytes = 0
  static let unacknowledgedLimit = 256 * 1024
  private var isHidden = false
  private let clock = ContinuousClock()
  private lazy var clockOrigin = clock.now
  static let pingInterval: Duration = .seconds(5)

  public init(
    config: CodevisorServerConfig,
    urlSession: URLSession = .shared,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    onEvent: @escaping EventHandler
  ) {
    self.sleep = sleep
    self.config = config
    self.requestTransport =
      config.requestTransport
      ?? URLSessionRequestTransport(session: urlSession)
    self.webSocketTransport =
      config.webSocketTransport
      ?? URLSessionWebSocketTransport(session: urlSession)
    self.onEvent = onEvent
  }

  public func open(sessionId: String, cwd: String, cols: Int, rows: Int) async throws {
    attachment = (sessionId, cwd)
    let created = try await requestTerminal(cols: cols, rows: rows, attachOnly: false)
    websocketPath = created.websocketPath
    lastOutputSeq = 0
    liveOutputSeq = created.nextOutputSeq
    connect()
  }

  private func requestTerminal(cols: Int, rows: Int, attachOnly: Bool) async throws -> TerminalCreated {
    struct Body: Encodable {
      var sessionId: String
      var cwd: String
      var cols: Int
      var rows: Int
      var attachOnly: Bool?
    }
    guard let attachment else { throw URLError(.cancelled) }
    var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/terminals"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyAuthorization(&request)
    request.httpBody = try JSONEncoder().encode(
      Body(
        sessionId: attachment.sessionId, cwd: attachment.cwd, cols: cols, rows: rows,
        attachOnly: attachOnly ? true : nil)
    )
    let (data, http) = try await requestTransport.data(for: request)
    guard (200...299).contains(http.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? ""
      throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: message])
    }
    return try JSONDecoder().decode(TerminalCreated.self, from: data)
  }

  private func refreshLiveOutputSeq() async {
    guard
      let head = try? await requestTerminal(
        cols: size?.cols ?? 80, rows: size?.rows ?? 24, attachOnly: true),
      head.websocketPath == websocketPath
    else { return }
    liveOutputSeq = max(liveOutputSeq, head.nextOutputSeq)
  }

  public func close() {
    guard !closed else { return }
    closed = true
    reconnectTask?.cancel()
    sendFrame(type: "close")
    teardownSocket()
  }

  public func detach() {
    closed = true
    reconnectTask?.cancel()
    teardownSocket()
  }

  public func sendInput(_ data: String) {
    guard !closed else { return }
    guard socket == nil else {
      sendFrame(type: "input", data: data)
      return
    }
    let bytes = data.utf8.count
    guard pendingInputBytes + bytes <= Self.pendingInputLimit else { return }
    clientSeq += 1
    pendingInput.append((clientSeq, data))
    pendingInputBytes += bytes
  }

  public func sendReply(_ data: String) {
    guard !closed, socket != nil else { return }
    sendFrame(type: "input", data: data, claims: false)
  }

  public func sendHidden() {
    isHidden = true
    claimed = false
    guard serverSpeaksProtocol2 else { return }
    sendFrame(type: "hide")
  }

  public var claimsSize: Bool { claimed }

  public func sendFocus() {
    guard !closed else { return }
    claimed = true
    claimSeq = Int.max
    guard serverSpeaksProtocol2 else { return }
    sendFrame(type: "focus")
  }

  public func reassertSize() {
    guard let size else { return }
    sendResize(cols: size.cols, rows: size.rows)
  }

  public func sendClear() {
    if serverSpeaksProtocol2 {
      sendFrame(type: "clear")
    } else {
      sendInput("\u{0C}")
    }
  }

  public func reconnectNow() {
    guard !closed, websocketPath != nil else { return }
    reconnectTask?.cancel()
    teardownSocket()
    failures = 0
    reconnectTask = Task { [weak self] in
      guard let self else { return }
      await self.refreshLiveOutputSeq()
      guard !Task.isCancelled else { return }
      self.connect()
    }
  }

  public func sendResize(cols: Int, rows: Int) {
    size = (cols, rows)
    isHidden = false
    sendFrame(type: "resize", cols: cols, rows: rows)
  }

  private func sendFrame(
    type: String, data: String? = nil, cols: Int? = nil, rows: Int? = nil, clientSeq assigned: Int? = nil,
    claims: Bool = true
  ) {
    guard let socket else { return }
    let seq: Int
    if let assigned {
      seq = assigned
    } else {
      clientSeq += 1
      seq = clientSeq
    }
    if claims, type == "input" || type == "focus" {
      claimed = true
      claimSeq = seq
    }
    let frame = ClientFrame(
      type: type, clientId: clientId, clientSeq: seq,
      data: data, cols: cols, rows: rows, claim: claims ? nil : false
    )
    guard let encoded = try? JSONEncoder().encode(frame),
      let text = String(data: encoded, encoding: .utf8)
    else { return }
    if !serverProtocolKnown || serverSpeaksProtocol2 {
      unacknowledged.append((seq, text))
      unacknowledgedBytes += text.utf8.count
      while unacknowledgedBytes > Self.unacknowledgedLimit, unacknowledged.count > 1 {
        unacknowledgedBytes -= unacknowledged.removeFirst().text.utf8.count
      }
    }
    transmit(text, on: socket)
  }

  private func transmit(_ text: String, on socket: any ServerWebSocketConnecting) {
    sendChain = Task { [previous = sendChain] in
      await previous.value
      try? await socket.send(.string(text))
    }
  }

  private func acknowledged(through clientSeq: Int) {
    acknowledgedSeq = max(acknowledgedSeq, clientSeq)
    while let first = unacknowledged.first, first.clientSeq <= clientSeq {
      unacknowledgedBytes -= first.text.utf8.count
      unacknowledged.removeFirst()
    }
  }

  private func connect() {
    guard !closed, let websocketPath,
      var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)
    else { return }
    components.scheme = config.baseURL.scheme == "https" ? "wss" : "ws"
    components.path = websocketPath
    components.query = "lastOutputSeq=\(lastOutputSeq)&protocol=2"
    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    applyAuthorization(&request)
    let socket = webSocketTransport.connect(request, maximumMessageSize: 8 * 1024 * 1024)
    self.socket = socket
    for frame in unacknowledged { transmit(frame.text, on: socket) }
    let queued = pendingInput
    pendingInput = []
    pendingInputBytes = 0
    for input in queued { sendFrame(type: "input", data: input.data, clientSeq: input.clientSeq) }
    if let size, !isHidden { sendFrame(type: "resize", cols: size.cols, rows: size.rows) }
    let inbound = TerminalInboundFrames(liveBoundary: liveOutputSeq)
    self.inbound = inbound
    receiveTask = Task { [weak self] in
      await self?.receiveLoop(socket, into: inbound)
    }
  }

  func drainInbound(_ inbound: TerminalInboundFrames, from socket: any ServerWebSocketConnecting) {
    guard self.inbound === inbound else { return }
    for item in inbound.take() {
      switch item {
      case let .frame(frame):
        if handleReceived(frame) { return }
      case .failed:
        handleReceiveFailure(on: socket)
        return
      }
    }
  }

  private func handleReceived(_ inbound: InboundTerminalFrame) -> Bool {
    failures = 0
    let frame = inbound.frame
    switch frame.type {
    case "ready":
      serverSpeaksProtocol2 = true
      serverProtocolKnown = true
      startPinging()
      if claimed, !isHidden, size != nil { sendFrame(type: "focus") }
      return false
    case "ack":
      if let clientSeq = frame.clientSeq { acknowledged(through: clientSeq) }
      return false
    case "pong":
      if let t = frame.t { recordRoundTrip(sentAt: t) }
      return false
    case "size":
      if let cols = frame.cols, let rows = frame.rows {
        if claimed, acknowledgedSeq >= claimSeq, let size, (cols, rows) != (size.cols, size.rows) {
          claimed = false
        }
        onEvent(.ptySize(cols: cols, rows: rows))
      }
      return false
    default:
      if !serverProtocolKnown {
        serverProtocolKnown = true
        unacknowledged = []
        unacknowledgedBytes = 0
      }
    }
    lastOutputSeq = max(lastOutputSeq, frame.seq)
    let isReset = frame.reset == true
    if isReset { replayedOutput = nil }
    let replayed = frame.seq < liveOutputSeq || isReset
    if !replayed { flushReplayedOutput() }
    defer {
      if replayed && (isReset || frame.seq >= liveOutputSeq - 1) { flushReplayedOutput() }
    }
    switch frame.type {
    case "output":
      if let output = inbound.output {
        if replayed {
          if replayedOutput == nil {
            replayedOutput = output
          } else {
            replayedOutput?.append(output)
          }
        } else {
          onEvent(.output(output, replayed: false))
        }
      }
    case "exit":
      flushReplayedOutput()
      closed = true
      teardownSocket()
      onEvent(.exit(code: frame.exitCode))
      return true
    case "error":
      flushReplayedOutput()
      onEvent(.error(frame.message ?? "Terminal error"))
    default:
      break
    }
    return false
  }

  private func flushReplayedOutput() {
    guard let output = replayedOutput else { return }
    replayedOutput = nil
    guard !output.bytes.isEmpty else { return }
    onEvent(.output(output, replayed: true))
  }

  private func handleReceiveFailure(on socket: any ServerWebSocketConnecting) {
    if self.socket === socket, !closed {
      scheduleReconnect()
    }
  }

  private func scheduleReconnect() {
    teardownSocket()
    failures += 1
    let base = min(5000, 250 * (1 << min(failures, 5)))
    let delay = base + Int.random(in: 0...250)
    reconnectTask = Task { [weak self, sleep] in
      try? await sleep(.milliseconds(delay))
      guard let self, !Task.isCancelled else { return }
      await self.refreshLiveOutputSeq()
      guard !Task.isCancelled else { return }
      self.connect()
    }
  }

  private func millisecondsSinceOrigin() -> Double {
    Self.milliseconds(clockOrigin.duration(to: clock.now))
  }

  private func startPinging() {
    pingTask?.cancel()
    guard let socket else { return }
    pingTask = Task { [weak self, sleep] in
      while !Task.isCancelled {
        guard let self else { return }
        var ping: [String: Any] = ["type": "ping", "t": self.millisecondsSinceOrigin()]
        if let rtt = self.roundTripTime { ping["srtt"] = Self.milliseconds(rtt) }
        if let data = try? JSONSerialization.data(withJSONObject: ping),
          let text = String(data: data, encoding: .utf8)
        {
          try? await socket.send(.string(text))
        }
        try? await sleep(Self.pingInterval)
      }
    }
  }

  private func recordRoundTrip(sentAt t: Double) {
    let sample = max(0, millisecondsSinceOrigin() - t)
    let smoothed = roundTripTime.map { Self.milliseconds($0) * 0.875 + sample * 0.125 } ?? sample
    roundTripTime = .microseconds(Int64(smoothed * 1000))
  }

  nonisolated public static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }

  private func teardownSocket() {
    pingTask?.cancel()
    pingTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    inbound?.close()
    inbound = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
  }

  private func applyAuthorization(_ request: inout URLRequest) {
    if let token = config.bearerToken, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
  }
}

fileprivate struct ClientFrame: Encodable {
  var type: String
  var clientId: String
  var clientSeq: Int
  var data: String?
  var cols: Int?
  var rows: Int?
  var claim: Bool?
}

struct TerminalServerFrame: Decodable, Sendable {
  var type: String
  var seq: Int
  var data: String?
  var exitCode: Int? = nil
  var message: String? = nil
  var reset: Bool?
  var t: Double? = nil
  var clientSeq: Int? = nil
  var cols: Int? = nil
  var rows: Int? = nil

  init(type: String, seq: Int, data: String? = nil, reset: Bool? = nil) {
    self.type = type
    self.seq = seq
    self.data = data
    self.reset = reset
  }
}
