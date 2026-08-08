import CryptoKit
import Foundation
import Network

/// A real local address for one cloud machine: a listener on
/// 127.0.0.1:<ephemeral port> that accepts plain HTTP/1.1 (and WebSocket
/// upgrade) connections and forwards them through the machine's end-to-end
/// encrypted relay — HTTP requests over "http" channels, WebSockets over "ws"
/// channels (the same machine-side handlers that back the in-app relay
/// transports).
///
/// It exists for baseURL consumers that can't use the in-process transports:
/// the Ghostty terminal pane spawns an external `codevisor-terminal-proxy`
/// process that dials `machine.baseURL` directly, which for cloud machines
/// used to be an unreachable placeholder. In-app clients keep using
/// `CloudRelayRequestTransport`/`CloudRelayWebSocketTransport` directly.
///
/// Headers are forwarded verbatim (including `Authorization`): the machine
/// side strips hop-by-hop headers plus `authorization` (that drop guards the
/// app's *cloud* bearer), and replays requests against its own loopback
/// origin, which is exempt from machine-token auth — so machine-token auth is
/// unaffected. Cloud-synthesized machines carry no token anyway.
///
/// v1 connection semantics: one HTTP request per connection (responses carry
/// `Connection: close`); WebSocket upgrades hold the connection open and
/// bridge RFC 6455 frames both ways until either side closes.
public final class CloudRelayLoopbackBridge: @unchecked Sendable {
    public enum BridgeError: Error, Sendable {
        case alreadyStarted
        case stopped
    }

    private let endpoint: CloudRelayEndpoint
    private let queue = DispatchQueue(label: "com.codevisor.cloud-loopback-bridge")
    private let lock = NSLock()
    private var listener: NWListener?
    private var stopped = false
    private var connections: [ObjectIdentifier: LoopbackConnection] = [:]
    /// The bound port once `start()` has succeeded.
    public private(set) var port: UInt16?

    public init(endpoint: CloudRelayEndpoint) {
        self.endpoint = endpoint
    }

    /// Starts listening on a loopback-only ephemeral port and returns it.
    /// Call once; the bridge is done after `stop()`.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        try lock.withLock {
            guard !stopped else { throw BridgeError.stopped }
            guard self.listener == nil else { throw BridgeError.alreadyStarted }
            self.listener = listener
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.adopt(connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // .ready can be followed by .failed/.cancelled later; resume once.
            let onceState = OnceFlag()
            @Sendable func resumeOnce(_ result: Result<UInt16, any Error>) {
                guard onceState.claim() else { return }
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        resumeOnce(.success(port))
                    } else {
                        resumeOnce(.failure(BridgeError.stopped))
                    }
                case let .failed(error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(BridgeError.stopped))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.port = port }
        Log.cloud.info("Cloud loopback bridge for \(self.endpoint.machineDeviceId, privacy: .public) listening on 127.0.0.1:\(port)")
        return port
    }

    /// Stops listening and closes every live connection (sign-out / machine
    /// removal).
    public func stop() {
        let (listener, open) = lock.withLock {
            stopped = true
            let result = (self.listener, Array(connections.values))
            self.listener = nil
            connections.removeAll()
            return result
        }
        listener?.cancel()
        for connection in open {
            connection.cancel()
        }
    }

    private func adopt(_ connection: NWConnection) {
        let handler = LoopbackConnection(connection: connection, endpoint: endpoint, queue: queue)
        let id = ObjectIdentifier(handler)
        let accepted = lock.withLock {
            guard !stopped else { return false }
            connections[id] = handler
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        Task { [weak self] in
            await handler.run()
            self?.lock.withLock { _ = self?.connections.removeValue(forKey: id) }
        }
    }

    // MARK: - WebSocket handshake

    /// A claim-once flag shared between the listener's state callbacks.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                let first = !claimed
                claimed = true
                return first
            }
        }
    }

    /// RFC 6455 §4.2.2: base64(SHA1(key ‖ magic GUID)).
    static func webSocketAccept(forKey key: String) -> String {
        let magic = key.trimmingCharacters(in: .whitespaces)
            + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }
}

// MARK: - One accepted connection

/// Serves one accepted loopback connection: parse the HTTP/1.1 head, then
/// either replay the request over an "http" relay channel or upgrade to a
/// WebSocket bridged onto a "ws" relay channel.
private final class LoopbackConnection: @unchecked Sendable {
    private static let maxHeadBytes = 64 * 1024
    private static let maxBodyBytes = 32 * 1024 * 1024
    private static let maxFramePayloadBytes = 16 * 1024 * 1024
    private static let headTerminator = Data("\r\n\r\n".utf8)

    private let connection: NWConnection
    private let endpoint: CloudRelayEndpoint
    private let queue: DispatchQueue
    /// Bytes received but not yet consumed by the head/body/frame parsers.
    private var buffer = Data()

    init(connection: NWConnection, endpoint: CloudRelayEndpoint, queue: DispatchQueue) {
        self.connection = connection
        self.endpoint = endpoint
        self.queue = queue
    }

    func cancel() {
        connection.cancel()
    }

    func run() async {
        connection.start(queue: queue)
        defer { connection.cancel() }
        do {
            guard let head = try await readHead() else { return }
            if head.isWebSocketUpgrade {
                try await serveWebSocket(head)
            } else {
                try await serveHTTP(head)
            }
        } catch {
            // The connection is torn down either way; a broken peer or a dead
            // relay is not this bridge's error to surface.
            Log.cloud.debug("Cloud loopback connection ended: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Socket I/O

    /// One received chunk, nil at EOF.
    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: HTTP head

    private struct RequestHead {
        var method: String
        /// Path + query exactly as sent ("/v1/terminals?x=1").
        var target: String
        /// In arrival order with original casing, forwarded verbatim.
        var headers: [(name: String, value: String)]

        func value(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var isWebSocketUpgrade: Bool {
            guard let upgrade = value("Upgrade") else { return false }
            return upgrade.lowercased().contains("websocket")
        }
    }

    private enum HTTPParseError: Error {
        case malformedHead
        case headTooLarge
        case bodyTooLarge
    }

    /// Reads and parses the request head; nil when the peer closes before
    /// sending one. Leftover bytes after the terminator stay in `buffer`.
    private func readHead() async throws -> RequestHead? {
        while true {
            if let range = buffer.firstRange(of: Self.headTerminator) {
                let headData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                return try Self.parseHead(headData)
            }
            guard buffer.count <= Self.maxHeadBytes else { throw HTTPParseError.headTooLarge }
            guard let chunk = try await receiveChunk() else {
                if buffer.isEmpty { return nil }
                throw HTTPParseError.malformedHead
            }
            buffer.append(chunk)
        }
    }

    private static func parseHead(_ data: Data) throws -> RequestHead {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformedHead }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[1].hasPrefix("/"),
              parts[2].hasPrefix("HTTP/1.")
        else { throw HTTPParseError.malformedHead }
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformedHead }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        return RequestHead(method: String(parts[0]), target: String(parts[1]), headers: headers)
    }

    // MARK: Plain HTTP

    private func serveHTTP(_ head: RequestHead) async throws {
        if head.value("Transfer-Encoding") != nil {
            try await send(Self.encodeResponse(status: 501, headers: [:], body: Data("chunked request bodies are not supported\n".utf8)))
            return
        }
        let contentLength = head.value("Content-Length").flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= Self.maxBodyBytes else {
            try await send(Self.encodeResponse(status: 413, headers: [:], body: Data()))
            return
        }
        while buffer.count < contentLength {
            guard let chunk = try await receiveChunk() else { throw HTTPParseError.malformedHead }
            buffer.append(chunk)
        }
        let body = buffer.prefix(contentLength)

        guard let url = URL(string: "http://127.0.0.1\(head.target)") else {
            try await send(Self.encodeResponse(status: 400, headers: [:], body: Data()))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = head.method
        for (name, value) in head.headers {
            // Verbatim: hop-by-hop (and any authorization) filtering is the
            // machine side's job; loopback replay is token-exempt there.
            request.addValue(value, forHTTPHeaderField: name)
        }
        if !body.isEmpty {
            request.httpBody = Data(body)
        }

        do {
            let transport = CloudRelayRequestTransport(endpoint: endpoint)
            let (responseBody, response) = try await transport.data(for: request)
            var headers: [(String, String)] = []
            for (name, value) in response.allHeaderFields {
                guard let name = name as? String, let value = value as? String else { continue }
                headers.append((name, value))
            }
            try await send(Self.encodeResponse(
                status: response.statusCode,
                headers: Dictionary(headers, uniquingKeysWith: { first, _ in first }),
                body: responseBody
            ))
        } catch {
            let message = "cloud relay error: \(error.localizedDescription)\n"
            try await send(Self.encodeResponse(status: 502, headers: [:], body: Data(message.utf8)))
        }
    }

    /// Headers the bridge owns on the loopback hop; relayed values for these
    /// would describe the machine-side hop, not this connection.
    private static let ownedResponseHeaders: Set<String> = [
        "connection", "content-length", "transfer-encoding", "keep-alive", "upgrade",
    ]

    private static func encodeResponse(status: Int, headers: [String: String], body: Data) -> Data {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        for (name, value) in headers where !ownedResponseHeaders.contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        return response
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    // MARK: WebSocket

    private enum WebSocketError: Error {
        case unmaskedClientFrame
        case payloadTooLarge
        case malformedFrame
    }

    private struct WebSocketFrame {
        var fin: Bool
        var opcode: UInt8
        var payload: Data
    }

    private func serveWebSocket(_ head: RequestHead) async throws {
        guard let key = head.value("Sec-WebSocket-Key"),
              let url = URL(string: "http://127.0.0.1\(head.target)")
        else {
            try await send(Self.encodeResponse(status: 400, headers: [:], body: Data()))
            return
        }
        let accept = CloudRelayLoopbackBridge.webSocketAccept(forKey: key)
        let handshake = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        try await send(Data(handshake.utf8))

        // The relay side: a "ws" channel to the machine, which bridges onto
        // the machine's local WebSocket endpoint for this path.
        let relay = CloudRelayWebSocketTransport(endpoint: endpoint).connect(
            URLRequest(url: url),
            maximumMessageSize: Self.maxFramePayloadBytes
        )

        // Machine → client: relay messages become unmasked server frames. A
        // clean channel close ("done") becomes WS close 1000, anything else
        // 1011. Cancelling the TCP connection unblocks the client read loop.
        let relayReader = Task { [connection] in
            while true {
                do {
                    let message = try await relay.receive()
                    switch message {
                    case let .string(text):
                        try await self.send(Self.encodeFrame(opcode: 0x1, payload: Data(text.utf8)))
                    case let .data(data):
                        try await self.send(Self.encodeFrame(opcode: 0x2, payload: data))
                    }
                } catch {
                    let clean = if case CloudRelayTransportError.channelClosed(.done) = error {
                        true
                    } else {
                        false
                    }
                    try? await self.send(Self.encodeFrame(
                        opcode: 0x8,
                        payload: Self.closePayload(code: clean ? 1000 : 1011)
                    ))
                    connection.cancel()
                    return
                }
            }
        }
        defer {
            relayReader.cancel()
            relay.cancel(with: .goingAway, reason: nil)
        }

        // Client → machine: parse masked client frames, forward data frames,
        // answer pings locally, stop on close.
        var fragmentOpcode: UInt8?
        var fragment = Data()
        while true {
            guard let frame = try Self.parseFrame(&buffer) else {
                guard let chunk = try await receiveChunk() else { return }
                buffer.append(chunk)
                continue
            }
            switch frame.opcode {
            case 0x1, 0x2:
                if frame.fin {
                    try await forward(opcode: frame.opcode, payload: frame.payload, to: relay)
                } else {
                    fragmentOpcode = frame.opcode
                    fragment = frame.payload
                }
            case 0x0:
                guard let opcode = fragmentOpcode else { throw WebSocketError.malformedFrame }
                guard fragment.count + frame.payload.count <= Self.maxFramePayloadBytes else {
                    throw WebSocketError.payloadTooLarge
                }
                fragment.append(frame.payload)
                if frame.fin {
                    try await forward(opcode: opcode, payload: fragment, to: relay)
                    fragmentOpcode = nil
                    fragment = Data()
                }
            case 0x8:
                // Echo the close (status code only) and let the deferred relay
                // cancel close the "ws" channel with "done".
                try? await send(Self.encodeFrame(opcode: 0x8, payload: frame.payload.prefix(2)))
                return
            case 0x9:
                try await send(Self.encodeFrame(opcode: 0xA, payload: frame.payload))
            case 0xA:
                break
            default:
                throw WebSocketError.malformedFrame
            }
        }
    }

    private func forward(
        opcode: UInt8,
        payload: Data,
        to relay: any ServerWebSocketConnecting
    ) async throws {
        if opcode == 0x1 {
            try await relay.send(.string(String(decoding: payload, as: UTF8.self)))
        } else {
            try await relay.send(.data(payload))
        }
    }

    /// Parses one client frame from `buffer` (consuming it), nil while the
    /// buffer holds only part of a frame. Client frames must be masked
    /// (RFC 6455 §5.1); the payload is unmasked here.
    private static func parseFrame(_ buffer: inout Data) throws -> WebSocketFrame? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        let fin = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        guard masked else { throw WebSocketError.unmaskedClientFrame }
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            var wide: UInt64 = 0
            for index in 2..<10 {
                wide = wide << 8 | UInt64(bytes[index])
            }
            guard wide <= UInt64(maxFramePayloadBytes) else { throw WebSocketError.payloadTooLarge }
            length = Int(wide)
            offset = 10
        }
        guard length <= maxFramePayloadBytes else { throw WebSocketError.payloadTooLarge }
        guard bytes.count >= offset + 4 + length else { return nil }
        let key = Array(bytes[offset..<offset + 4])
        let payloadStart = offset + 4
        var payload = [UInt8](repeating: 0, count: length)
        for index in 0..<length {
            payload[index] = bytes[payloadStart + index] ^ key[index % 4]
        }
        buffer = buffer.subdata(in: buffer.startIndex.advanced(by: payloadStart + length)..<buffer.endIndex)
        return WebSocketFrame(fin: fin, opcode: opcode, payload: Data(payload))
    }

    /// One FIN server frame, unmasked (RFC 6455 §5.1: server frames must not
    /// be masked).
    private static func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(count >> 8))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((count >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    private static func closePayload(code: UInt16) -> Data {
        Data([UInt8(code >> 8), UInt8(code & 0xFF)])
    }
}
