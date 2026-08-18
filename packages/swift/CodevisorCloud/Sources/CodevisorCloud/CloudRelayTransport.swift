import ACPKit
import CodevisorClient
import Foundation

/// One machine reachable over the cloud relay: which hub to go through and
/// the machine's pinned identity.
public struct CloudRelayEndpoint: Sendable {
    public let hub: CloudHubConnection
    public let machineDeviceId: String
    public let machinePublicKey: String

    public init(hub: CloudHubConnection, machineDeviceId: String, machinePublicKey: String) {
        self.hub = hub
        self.machineDeviceId = machineDeviceId
        self.machinePublicKey = machinePublicKey
    }
}

public enum CloudRelayTransportError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest
    case invalidFrame
    case channelClosed(CloudChannelCloseReason?)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The request cannot be sent over the cloud relay."
        case .invalidFrame:
            "The machine sent an unexpected relay frame."
        case let .channelClosed(reason):
            switch reason {
            case .rejected:
                "The machine rejected the request."
            case .none:
                "The cloud relay connection was interrupted."
            default:
                "The relay channel closed (\(reason?.rawValue ?? "unknown"))."
            }
        case .timedOut:
            "The request over the cloud relay timed out."
        }
    }
}

/// Tunnels ordinary HTTP requests through an "http" relay channel: the open
/// params carry method/path/headers, the body streams as base64url chunks,
/// and the machine answers head → chunks → end → close("done").
public struct CloudRelayRequestTransport: ServerRequestTransport {
    /// Raw bytes per body chunk frame (b64url expansion happens on top).
    public static let chunkSize = 262_144
    /// A relayed request whose channel never answers must fail visibly
    /// instead of hanging its caller (and any UI gated on it) forever.
    public static let defaultTimeout: Duration = .seconds(30)

    private let endpoint: CloudRelayEndpoint
    private let timeout: Duration

    public init(endpoint: CloudRelayEndpoint, timeout: Duration = CloudRelayRequestTransport.defaultTimeout) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    private struct ClientFrame: Encodable {
        var kind: String
        var data: String?
    }

    private struct MachineFrame: Decodable {
        var kind: String
        var status: Int?
        var headers: [String: String]?
        var data: String?
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let timeout = timeout
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask {
                try await perform(request)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CloudRelayTransportError.timedOut
            }
            // Whichever finishes first wins; the loser is cancelled when the
            // group scope ends (cancellation unblocks the frame stream, and
            // the request task then closes its channel on the way out).
            guard let result = try await group.next() else {
                throw CloudRelayTransportError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw CloudRelayTransportError.invalidRequest }
        var path = components.path.isEmpty ? "/" : components.path
        if let query = components.query, !query.isEmpty {
            path += "?\(query)"
        }
        let headers = request.allHTTPHeaderFields ?? [:]
        let params: JSONValue = .object([
            "method": .string(request.httpMethod ?? "GET"),
            "path": .string(path),
            "headers": .object(headers.mapValues { .string($0) }),
        ])

        let (frames, continuation) = AsyncThrowingStream<MachineFrame, any Error>.makeStream()
        let decoder = JSONDecoder()
        let channel = try await endpoint.hub.openChannel(
            machineDeviceId: endpoint.machineDeviceId,
            machinePublicKey: endpoint.machinePublicKey,
            channelType: "http",
            params: params,
            onMessage: { data in
                if let frame = try? decoder.decode(MachineFrame.self, from: data) {
                    continuation.yield(frame)
                } else {
                    continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                }
            },
            onClosed: { reason in
                if reason == .done {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: CloudRelayTransportError.channelClosed(reason))
                }
            }
        )

        do {
            if let body = request.httpBody, !body.isEmpty {
                var offset = body.startIndex
                while offset < body.endIndex {
                    let end =
                        body.index(offset, offsetBy: Self.chunkSize, limitedBy: body.endIndex)
                        ?? body.endIndex
                    try await channel.sendJSON(
                        ClientFrame(
                            kind: "chunk",
                            data: CloudChannelCrypto.base64URLEncode(body[offset..<end])
                        ))
                    offset = end
                }
            }
            try await channel.sendJSON(ClientFrame(kind: "end"))

            var status: Int?
            var responseHeaders: [String: String] = [:]
            var body = Data()
            var sawEnd = false
            for try await frame in frames {
                switch frame.kind {
                case "head":
                    guard let frameStatus = frame.status else {
                        throw CloudRelayTransportError.invalidFrame
                    }
                    status = frameStatus
                    responseHeaders = frame.headers ?? [:]
                case "chunk":
                    guard status != nil,
                        let encoded = frame.data,
                        let chunk = CloudChannelCrypto.base64URLDecode(encoded)
                    else { throw CloudRelayTransportError.invalidFrame }
                    body.append(chunk)
                case "end":
                    sawEnd = true
                default:
                    throw CloudRelayTransportError.invalidFrame
                }
                if sawEnd { break }
            }
            guard let status, sawEnd,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: responseHeaders
                )
            else { throw CloudRelayTransportError.channelClosed(nil) }
            await channel.close(reason: .done)
            return (body, response)
        } catch {
            await channel.close(reason: .done)
            throw error
        }
    }
}

/// Tunnels WebSocket connections through a "ws" relay channel — the socket
/// sibling of `CloudRelayRequestTransport`, used for event streams and
/// terminals.
public struct CloudRelayWebSocketTransport: ServerWebSocketTransport {
    private let endpoint: CloudRelayEndpoint

    public init(endpoint: CloudRelayEndpoint) {
        self.endpoint = endpoint
    }

    public func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
        CloudRelayWebSocketConnection(endpoint: endpoint, request: request)
    }
}

/// One relayed WebSocket: lazily opens a "ws" channel for the request's path
/// and adapts `{kind: text|binary}` frames to `ServerWebSocketMessage`.
/// Single-consumer, like a URLSessionWebSocketTask receive loop.
final class CloudRelayWebSocketConnection: ServerWebSocketConnecting, @unchecked Sendable {
    private struct WsFrame: Codable {
        var kind: String
        var data: String
    }

    /// Accumulates chunked-message byte slices between `part` frames and the
    /// typed end frame. Accessed only from the hub actor's onMessage calls;
    /// @unchecked Sendable covers the closure capture, not concurrent use.
    private final class PartAccumulator: @unchecked Sendable {
        private var bytes = Data()

        func append(base64URL piece: String) -> Bool {
            guard let decoded = CloudChannelCrypto.base64URLDecode(piece) else { return false }
            bytes.append(decoded)
            return true
        }

        func finish(base64URL piece: String) -> Data? {
            guard let decoded = CloudChannelCrypto.base64URLDecode(piece) else {
                bytes.removeAll()
                return nil
            }
            var message = bytes
            message.append(decoded)
            bytes.removeAll()
            return message
        }
    }

    private let lock = NSLock()
    private let openTask: Task<CloudRelayChannel, any Error>
    private var iterator: AsyncThrowingStream<ServerWebSocketMessage, any Error>.Iterator
    private var cancelled = false

    init(endpoint: CloudRelayEndpoint, request: URLRequest) {
        let (messages, continuation) = AsyncThrowingStream<ServerWebSocketMessage, any Error>.makeStream()
        iterator = messages.makeAsyncIterator()

        var path = "/"
        if let url = request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        {
            path = components.path.isEmpty ? "/" : components.path
            if let query = components.query, !query.isEmpty {
                path += "?\(query)"
            }
        }
        let decoder = JSONDecoder()
        // Reassembly buffer for chunked messages: `part` frames accumulate
        // byte slices until a typed end frame closes the message. Machines
        // split anything above the chunk cap so a single huge event cannot
        // exceed the hub's relay frame limit (whose dropped-frame seq gap
        // would abort the channel and livelock cursor replay). Calls arrive
        // serialized through the hub actor, so plain state suffices.
        let pendingParts = PartAccumulator()
        openTask = Task {
            let channel = try await endpoint.hub.openChannel(
                machineDeviceId: endpoint.machineDeviceId,
                machinePublicKey: endpoint.machinePublicKey,
                channelType: "ws",
                params: .object(["path": .string(path)]),
                onMessage: { data in
                    guard let frame = try? decoder.decode(WsFrame.self, from: data) else {
                        continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                        return
                    }
                    switch frame.kind {
                    case "text":
                        continuation.yield(.string(frame.data))
                    case "binary":
                        if let decoded = CloudChannelCrypto.base64URLDecode(frame.data) {
                            continuation.yield(.data(decoded))
                        } else {
                            continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                        }
                    case "part":
                        if !pendingParts.append(base64URL: frame.data) {
                            continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                        }
                    case "text-end":
                        if let message = pendingParts.finish(base64URL: frame.data) {
                            continuation.yield(.string(String(decoding: message, as: UTF8.self)))
                        } else {
                            continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                        }
                    case "binary-end":
                        if let message = pendingParts.finish(base64URL: frame.data) {
                            continuation.yield(.data(message))
                        } else {
                            continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                        }
                    default:
                        break
                    }
                },
                onClosed: { reason in
                    if reason == .done {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: CloudRelayTransportError.channelClosed(reason))
                    }
                }
            )
            return channel
        }
    }

    func send(_ message: ServerWebSocketMessage) async throws {
        let channel = try await openTask.value
        switch message {
        case let .string(text):
            try await channel.sendJSON(WsFrame(kind: "text", data: text))
        case let .data(data):
            try await channel.sendJSON(WsFrame(kind: "binary", data: CloudChannelCrypto.base64URLEncode(data)))
        }
    }

    func receive() async throws -> ServerWebSocketMessage {
        // Ensure the channel is (being) opened before waiting for frames.
        _ = try await openTask.value
        guard let message = try await iterator.next() else {
            // The peer finished cleanly; a socket consumer expects a throw
            // (like URLSession's receive on a closed socket) to trigger its
            // reconnect/teardown path.
            throw CloudRelayTransportError.channelClosed(.done)
        }
        return message
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let shouldClose = lock.withLock {
            let first = !cancelled
            cancelled = true
            return first
        }
        guard shouldClose else { return }
        let openTask = openTask
        Task {
            if let channel = try? await openTask.value {
                await channel.close(reason: .done)
            }
        }
    }

    var closeCode: URLSessionWebSocketTask.CloseCode {
        .invalid
    }
}
