import Foundation

/// `POST /v1/terminals` response.
public struct TerminalCreated: Decodable, Sendable {
    public var terminalId: String
    public var websocketPath: String
    public var nextOutputSeq: Int
}

/// Server-to-client terminal activity, delivered in sequence order.
public enum TerminalEvent: Sendable {
    case output(String)
    case exit(code: Int?)
    case error(String)
}

/// The remote-terminal wire protocol: create a server-side PTY (or attach to
/// an existing one) and stream it over a WebSocket of JSON frames. The PTY
/// lives in the server's TerminalManager and survives disconnects — reconnects
/// replay every frame after `lastOutputSeq`. This is the same protocol the web
/// client (apps/web/src/lib/terminal.ts) and the macOS terminal proxy speak;
/// the renderer on top is platform-owned.
///
/// Auth note: the server honors the `Authorization: Bearer` handshake header
/// (the web client's `?token=` query is ignored and only works on loopback),
/// so this transport always authenticates via the header.
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
    private let clientId = UUID().uuidString
    private var clientSeq = 0
    private var lastOutputSeq = 0
    private var websocketPath: String?
    private var socket: (any ServerWebSocketConnecting)?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Serializes outbound frames: WebSocket sends through the seam are async,
    /// and input/resize frames must arrive in the order they were produced.
    private var sendChain: Task<Void, Never> = Task {}
    private var failures = 0
    private var closed = false

    public init(
        config: CodevisorServerConfig,
        urlSession: URLSession = .shared,
        onEvent: @escaping EventHandler
    ) {
        self.config = config
        self.requestTransport = config.requestTransport
            ?? URLSessionRequestTransport(session: urlSession)
        self.webSocketTransport = config.webSocketTransport
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
        struct Body: Encodable {
            var sessionId: String
            var cwd: String
            var cols: Int
            var rows: Int
            var attachOnly: Bool?
        }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/terminals"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorization(&request)
        request.httpBody = try JSONEncoder().encode(
            Body(sessionId: sessionId, cwd: cwd, cols: cols, rows: rows, attachOnly: attachOnly ? true : nil)
        )
        let (data, http) = try await requestTransport.data(for: request)
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let created = try JSONDecoder().decode(TerminalCreated.self, from: data)
        websocketPath = created.websocketPath
        // Attach from seq 0 so the server replays the terminal's buffered
        // scrollback into this fresh renderer (reusing a session's live PTY
        // returns the existing terminal — seeding the cursor at the current
        // head here would skip all history). In-process reconnects advance
        // lastOutputSeq from received frames, so nothing replays twice.
        lastOutputSeq = 0
        connect()
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
        sendFrame(type: "input", data: data)
    }

    public func sendResize(cols: Int, rows: Int) {
        sendFrame(type: "resize", cols: cols, rows: rows)
    }

    // MARK: - Frames

    private struct ClientFrame: Encodable {
        var type: String
        var clientId: String
        var clientSeq: Int
        var data: String?
        var cols: Int?
        var rows: Int?
    }

    private struct ServerFrame: Decodable {
        var type: String
        var seq: Int
        var data: String?
        var exitCode: Int?
        var message: String?
    }

    private func sendFrame(type: String, data: String? = nil, cols: Int? = nil, rows: Int? = nil) {
        guard let socket else { return }
        clientSeq += 1
        let frame = ClientFrame(
            type: type, clientId: clientId, clientSeq: clientSeq,
            data: data, cols: cols, rows: rows
        )
        guard let encoded = try? JSONEncoder().encode(frame),
              let text = String(data: encoded, encoding: .utf8) else { return }
        sendChain = Task { [previous = sendChain] in
            await previous.value
            try? await socket.send(.string(text))
        }
    }

    // MARK: - Socket lifecycle

    private func connect() {
        guard !closed, let websocketPath,
              var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)
        else { return }
        components.scheme = config.baseURL.scheme == "https" ? "wss" : "ws"
        components.path = websocketPath
        components.query = "lastOutputSeq=\(lastOutputSeq)"
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        applyAuthorization(&request)
        let socket = webSocketTransport.connect(request, maximumMessageSize: 8 * 1024 * 1024)
        self.socket = socket
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket)
        }
    }

    private func receiveLoop(_ socket: any ServerWebSocketConnecting) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                failures = 0
                guard case let .string(text) = message,
                      let frame = try? JSONDecoder().decode(ServerFrame.self, from: Data(text.utf8))
                else { continue }
                lastOutputSeq = max(lastOutputSeq, frame.seq)
                switch frame.type {
                case "output":
                    if let data = frame.data { onEvent(.output(data)) }
                case "exit":
                    closed = true
                    teardownSocket()
                    onEvent(.exit(code: frame.exitCode))
                    return
                case "error":
                    onEvent(.error(frame.message ?? "Terminal error"))
                default:
                    continue
                }
            } catch {
                if self.socket === socket, !closed {
                    scheduleReconnect()
                }
                return
            }
        }
    }

    private func scheduleReconnect() {
        teardownSocket()
        failures += 1
        // Same curve as the web client: 250ms · 2^n capped at 5s, plus jitter.
        let base = min(5000, 250 * (1 << min(failures, 5)))
        let delay = base + Int.random(in: 0...250)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.connect()
        }
    }

    private func teardownSocket() {
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
