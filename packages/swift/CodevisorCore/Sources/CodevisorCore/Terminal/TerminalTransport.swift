import Foundation

/// `POST /v1/terminals` response.
public struct TerminalCreated: Decodable, Sendable {
  public var terminalId: String
  public var websocketPath: String
  public var nextOutputSeq: Int
}

/// Server-to-client terminal activity, delivered in sequence order.
public enum TerminalEvent: Sendable {
  /// `replayed` marks history the server buffered before this attach,
  /// delivered as one event once all of it has arrived: rendered frame by
  /// frame it would visibly play back every full-screen app the terminal
  /// ever ran. It also holds the queries apps sent back then (colors,
  /// modes, device attributes), which a renderer must not answer again: the
  /// replies would land as input in whatever runs now, typically the
  /// shell's prompt.
  case output(String, replayed: Bool)
  case exit(code: Int?)
  case error(String)
  /// The PTY's size: set by the client being typed on. A client showing a
  /// larger PTY than its own grid fits it to its screen rather than
  /// reflowing it.
  case ptySize(cols: Int, rows: Int)
}

/// The remote-terminal wire protocol: create a server-side PTY (or attach to
/// an existing one) and stream it over a WebSocket of JSON frames. The PTY
/// lives in the server's TerminalManager and survives disconnects — reconnects
/// replay every frame after `lastOutputSeq`. Both apps' libghostty surfaces
/// use it through TerminalController; the CLI's terminal proxy speaks the
/// same protocol.
///
/// Auth note: the server honors the `Authorization: Bearer` handshake header
/// and ignores query-string tokens, so this transport always authenticates via
/// the header.
///
/// Both the HTTP create call and the WebSocket go through the config's
/// transport seams, so a cloud machine's relay-backed config makes terminals
/// tunnel with no changes here or at call sites.
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
  /// Frames numbered below this were buffered before the attach, or before
  /// the latest reconnect.
  private var liveOutputSeq = 0
  private var attachment: (sessionId: String, cwd: String, attachOnly: Bool)?
  /// Replayed output received so far, held until the history is complete.
  private var replayedOutput = ""
  private var websocketPath: String?
  private var socket: (any ServerWebSocketConnecting)?
  private var receiveTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  /// Serializes outbound frames: WebSocket sends through the seam are async,
  /// and input/resize frames must arrive in the order they were produced.
  private var sendChain: Task<Void, Never> = Task {}
  private var failures = 0
  private var closed = false
  /// The latest size the renderer asked for. A resize can arrive before the
  /// socket exists (the view lays out while the terminal is still being
  /// created) and a reconnect opens a fresh socket, so it is sent again on
  /// every connect; otherwise the shell keeps a stale width and redraws its
  /// prompt over itself.
  private var size: (cols: Int, rows: Int)?
  /// Input typed while the socket is down (a reconnect, the app returning
  /// from the background), sent in order once it is back. Each frame keeps
  /// the sequence number it was given when typed, so the server's
  /// duplicate check still holds across the reconnect. Bounded: a paste
  /// into a long-dead connection must not grow without limit.
  private var pendingInput: [(clientSeq: Int, data: String)] = []
  private var pendingInputBytes = 0
  static let pendingInputLimit = 64 * 1024
  /// Smoothed round trip to the server (RFC 6298 style, 1/8 gain), measured
  /// with pings once the server says it speaks protocol 2. Nil until the
  /// first pong. Drives the server's output pacing and local echo.
  public private(set) var roundTripTime: Duration?
  private var pingTask: Task<Void, Never>?
  /// The server announced protocol 2 (a `ready` frame): it understands
  /// `hide` and `clear`.
  private var serverSpeaksProtocol2 = false
  /// Whether the server has said which protocol it speaks (its first frame).
  private var serverProtocolKnown = false
  /// Frames sent but not yet acknowledged (protocol 2), resent first after a
  /// reconnect: a socket can die with frames still in it, and the server's
  /// duplicate check by clientSeq makes the resend safe. Kept until the
  /// server turns out not to acknowledge (protocol 1), and bounded.
  private var unacknowledged: [(clientSeq: Int, text: String)] = []
  /// The highest client frame the server has acknowledged.
  private var acknowledgedSeq = 0
  /// This client was used (typed on, or its terminal opened, tapped or
  /// clicked into), so it owns the PTY's size until another client is used.
  /// A reconnect claims it again, unless another client has taken it since.
  private var claimed = false
  /// The frame that last claimed the size; `size` frames before the server
  /// handled it are stale.
  private var claimSeq = Int.max
  private var unacknowledgedBytes = 0
  static let unacknowledgedLimit = 256 * 1024
  /// Off screen: this client's size doesn't constrain the PTY, so it isn't
  /// sent again on reconnect until the terminal is shown.
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

  /// Creates (or, idempotently per session key, reuses) the server-side
  /// terminal and starts streaming. `attachOnly` never spawns a shell —
  /// for agent-owned background-task terminals.
  public func open(
    sessionId: String,
    cwd: String,
    cols: Int,
    rows: Int,
    attachOnly: Bool = false
  ) async throws {
    attachment = (sessionId, cwd, attachOnly)
    let created = try await requestTerminal(cols: cols, rows: rows, attachOnly: attachOnly)
    websocketPath = created.websocketPath
    // Attach from seq 0 so the server replays the terminal's buffered
    // scrollback into this fresh renderer (reusing a session's live PTY
    // returns the existing terminal — seeding the cursor at the current
    // head here would skip all history). In-process reconnects advance
    // lastOutputSeq from received frames, so nothing replays twice.
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

  /// Before a reconnect, learns where the output this client missed ends:
  /// it is history like an attach's, including queries another client may
  /// already have answered, and is delivered the same way. Asking with
  /// `attachOnly` never spawns a shell. When the terminal is gone the
  /// reconnect still goes ahead and receives its exit.
  private func refreshLiveOutputSeq() async {
    guard
      let head = try? await requestTerminal(
        cols: size?.cols ?? 80, rows: size?.rows ?? 24, attachOnly: true),
      head.websocketPath == websocketPath
    else { return }
    liveOutputSeq = max(liveOutputSeq, head.nextOutputSeq)
  }

  /// Ends the shell: sends the close frame (killing the PTY) and stops.
  public func close() {
    guard !closed else { return }
    closed = true
    reconnectTask?.cancel()
    sendFrame(type: "close")
    teardownSocket()
  }

  /// Drops the socket but leaves the server-side PTY running (scrollback
  /// replays on the next attach).
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

  /// The terminal's own answer to a program's query: input for the program,
  /// but not a sign anyone is using this client, so it doesn't take the
  /// PTY's size. Dropped while disconnected — the question is stale by then.
  public func sendReply(_ data: String) {
    guard !closed, socket != nil else { return }
    sendFrame(type: "input", data: data, claims: false)
  }

  /// The terminal went off screen (a hidden pane, a backgrounded app): the
  /// PTY is sized for the clients still showing it. Showing it again is a
  /// resize (`reassertSize`).
  public func sendHidden() {
    isHidden = true
    claimed = false
    guard serverSpeaksProtocol2 else { return }
    sendFrame(type: "hide")
  }

  /// Whether this client owns the PTY's size, as far as it knows.
  public var claimsSize: Bool { claimed }

  /// This client is being used (its terminal opened, tapped or clicked
  /// into): it takes the PTY's size, as typing on it does.
  public func sendFocus() {
    guard !closed else { return }
    claimed = true
    claimSeq = Int.max
    // Before the server has said it speaks protocol 2, `ready` sends it.
    guard serverSpeaksProtocol2 else { return }
    sendFrame(type: "focus")
  }

  /// Sends this client's size again, e.g. when its terminal is shown.
  public func reassertSize() {
    guard let size else { return }
    sendResize(cols: size.cols, rows: size.rows)
  }

  /// ⌘K: clears the terminal for every client (the server decides what's
  /// safe to clear). An older server gets Ctrl-L, which a shell at its
  /// prompt handles the same way minus the scrollback.
  public func sendClear() {
    if serverSpeaksProtocol2 {
      sendFrame(type: "clear")
    } else {
      sendInput("\u{0C}")
    }
  }

  /// Replaces the socket right away instead of waiting for it to fail: iOS
  /// can keep a half-open WebSocket across suspension or a network handoff,
  /// which otherwise only errors out after a long timeout. Output missed in
  /// the meantime replays from the last received sequence number.
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

  // MARK: - Frames

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

  // MARK: - Socket lifecycle

  private func connect() {
    guard !closed, let websocketPath,
      var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)
    else { return }
    components.scheme = config.baseURL.scheme == "https" ? "wss" : "ws"
    components.path = websocketPath
    // protocol=2: binary output frames and round-trip probes. Servers that
    // predate it ignore the parameter and keep sending JSON text.
    components.query = "lastOutputSeq=\(lastOutputSeq)&protocol=2"
    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    applyAuthorization(&request)
    let socket = webSocketTransport.connect(request, maximumMessageSize: 8 * 1024 * 1024)
    self.socket = socket
    // Queued input carries older sequence numbers than anything sent now, so
    // it goes first; the resize after it gets a fresh, higher number.
    // Frames a dead socket may have swallowed go again first: they're older
    // than anything queued since.
    for frame in unacknowledged { transmit(frame.text, on: socket) }
    let queued = pendingInput
    pendingInput = []
    pendingInputBytes = 0
    for input in queued { sendFrame(type: "input", data: input.data, clientSeq: input.clientSeq) }
    if let size, !isHidden { sendFrame(type: "resize", cols: size.cols, rows: size.rows) }
    receiveTask = Task { [weak self] in
      await self?.receiveLoop(socket)
    }
  }

  /// Receives and JSON-decodes frames off the main actor (frames arrive at
  /// very high frequency during builds and can be up to 8MB), then hands
  /// each decoded frame to the main actor in receive order — decode of the
  /// next frame only starts after the previous one was handled.
  nonisolated private func receiveLoop(_ socket: any ServerWebSocketConnecting) async {
    let decoder = JSONDecoder()
    while !Task.isCancelled {
      do {
        let message = try await socket.receive()
        let frame: ServerFrame? =
          switch message {
          case .string(let text): try? decoder.decode(ServerFrame.self, from: Data(text.utf8))
          case .data(let data): Self.decodeBinaryOutput(data)
          }
        if await handleReceived(frame) { return }
      } catch {
        await handleReceiveFailure(on: socket)
        return
      }
    }
  }

  /// Protocol 2 output: kind byte (1 output, 2 reset), sequence number as a
  /// big-endian u64, then UTF-8 output.
  nonisolated private static func decodeBinaryOutput(_ data: Data) -> ServerFrame? {
    let bytes = [UInt8](data)
    guard bytes.count >= 9, bytes[0] == 1 || bytes[0] == 2 else { return nil }
    let seq = bytes[1..<9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    return ServerFrame(
      type: "output", seq: Int(seq), data: String(decoding: bytes[9...], as: UTF8.self),
      reset: bytes[0] == 2 ? true : nil)
  }

  /// Main-actor half of the receive loop. Returns true when the loop should
  /// stop (terminal exited).
  private func handleReceived(_ frame: ServerFrame?) -> Bool {
    failures = 0
    guard let frame else { return false }
    switch frame.type {
    case "ready":
      serverSpeaksProtocol2 = true
      serverProtocolKnown = true
      startPinging()
      // Reconnected (or connected) while this client owns the size.
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
        // Another client took the size after this one's claim.
        if claimed, acknowledgedSeq >= claimSeq, let size, (cols, rows) != (size.cols, size.rows) {
          claimed = false
        }
        onEvent(.ptySize(cols: cols, rows: rows))
      }
      return false
    default:
      // A server that starts with anything but `ready` predates protocol 2
      // and never acknowledges: stop keeping frames for it.
      if !serverProtocolKnown {
        serverProtocolKnown = true
        unacknowledged = []
        unacknowledgedBytes = 0
      }
    }
    lastOutputSeq = max(lastOutputSeq, frame.seq)
    // A reconstruction replaces everything before it and, like history,
    // holds queries that were already answered.
    let isReset = frame.reset == true
    if isReset { replayedOutput = "" }
    let replayed = frame.seq < liveOutputSeq || isReset
    if !replayed { flushReplayedOutput() }
    defer {
      // The history's last frame completes it.
      if replayed && (isReset || frame.seq >= liveOutputSeq - 1) { flushReplayedOutput() }
    }
    switch frame.type {
    case "output":
      if let data = frame.data {
        if replayed {
          replayedOutput += data
        } else {
          onEvent(.output(data, replayed: false))
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
    guard !replayedOutput.isEmpty else { return }
    let output = replayedOutput
    replayedOutput = ""
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
    // Exponential reconnect: 250ms · 2^n capped at 5s, plus jitter.
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
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
  }

  private func applyAuthorization(_ request: inout URLRequest) {
    if let token = config.bearerToken, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
  }
}

// MARK: - Wire frames

fileprivate struct ClientFrame: Encodable {
  var type: String
  var clientId: String
  var clientSeq: Int
  var data: String?
  var cols: Int?
  var rows: Int?
  /// `input`: false for a query reply, which doesn't take the PTY's size.
  var claim: Bool?
}

fileprivate struct ServerFrame: Decodable, Sendable {
  var type: String
  var seq: Int
  var data: String?
  var exitCode: Int?
  var message: String?
  /// The server's reconstruction of the screen, sent when this client's
  /// cursor is older than the output it still retains.
  var reset: Bool?
  /// `pong`: the ping's timestamp, echoed.
  var t: Double?
  /// `ack`: the client frame handled.
  var clientSeq: Int?
  /// `size`: the PTY's size.
  var cols: Int?
  var rows: Int?
}
