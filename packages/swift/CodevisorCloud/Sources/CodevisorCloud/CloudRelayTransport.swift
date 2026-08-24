import ACPKit
import CodevisorClient
import Foundation

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

/// Shared window sizing for the flow-controlled http/ws relay channels
/// (twin of @codevisor/cloud-client PROXY_INITIAL_CREDIT_BYTES): each
/// receiver grants this much ciphertext budget up front and replenishes as
/// it consumes, so no hop ever holds more than the window in flight.
enum CloudRelayProxy {
    static let initialCreditBytes = 1024 * 1024
}

/// Tunnels ordinary HTTP requests through a flow-controlled "http" relay
/// channel: the open params carry method/path/headers, the body streams as
/// base64url chunks (gated on the machine's credit grants), and the machine
/// answers head → chunks → end → close("done") behind ours. `stream(for:)`
/// hands chunks to the caller as they arrive and replenishes the machine's
/// window per pulled chunk, so a 32MB download is paced by its consumer
/// instead of buffered anywhere.
public struct CloudRelayRequestTransport: ServerRequestTransport {
    /// Raw bytes per body chunk frame (b64url expansion happens on top).
    public static let chunkSize = 262_144
    /// A relayed request whose channel never answers must fail visibly
    /// instead of hanging its caller (and any UI gated on it) forever.
    public static let defaultTimeout: Duration = .seconds(30)

    private let endpoint: any CloudChannelTransport
    private let timeout: Duration

    public init(
        endpoint: any CloudChannelTransport,
        timeout: Duration = CloudRelayRequestTransport.defaultTimeout
    ) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    private struct ClientFrame: Encodable {
        var kind: String
        var data: String?
    }

    struct MachineFrame: Decodable {
        var kind: String
        var status: Int?
        var headers: [String: String]?
        var data: String?
    }

    struct WireFrame {
        var frame: MachineFrame
        var sealedBytes: Int
    }

    /// The whole request/response under one deadline, body buffered — the
    /// JSON API surface. Streaming callers use `stream(for:)`.
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await raced(timeout: timeout) {
            let (response, source) = try await performStream(request)
            var body = Data()
            do {
                while let chunk = try await source.nextBodyChunk() {
                    body.append(chunk)
                }
            } catch {
                await source.finish(reason: .done)
                throw error
            }
            return (body, response)
        }
    }

    /// Streams the response: the head is bounded by the transport timeout,
    /// the body is paced by the consumer (each pulled chunk replenishes the
    /// machine's send window). The stream must be drained or cancelled — a
    /// cancelled/failed pull closes the channel on the way out.
    public func stream(
        for request: URLRequest
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
        let (response, source) = try await raced(timeout: timeout) {
            try await performStream(request)
        }
        let body = AsyncThrowingStream<Data, any Error>(unfolding: {
            do {
                return try await source.nextBodyChunk()
            } catch {
                await source.finish(reason: .done)
                throw error
            }
        })
        return (response, body)
    }

    /// Races `operation` against the transport deadline; the loser is
    /// cancelled (cancellation unblocks the frame stream, and the request
    /// path then closes its channel on the way out).
    private func raced<Value: Sendable>(
        timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CloudRelayTransportError.timedOut
            }
            guard let result = try await group.next() else {
                throw CloudRelayTransportError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    /// Opens the channel, uploads the request, and consumes frames up to and
    /// including the head. The returned source yields decoded body chunks.
    private func performStream(
        _ request: URLRequest
    ) async throws -> (HTTPURLResponse, HttpResponseSource) {
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

        let (frames, continuation) = AsyncThrowingStream<WireFrame, any Error>.makeStream()
        let gate = CloudChannelCreditGate()
        let decoder = JSONDecoder()
        let channel = try await endpoint.openFlowControlledChannel(
            channelType: "http",
            params: params,
            compressed: true,
            onMessage: { data, sealedBytes in
                if let frame = try? decoder.decode(MachineFrame.self, from: data) {
                    continuation.yield(WireFrame(frame: frame, sealedBytes: sealedBytes))
                } else {
                    continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                }
            },
            onCredit: { bytes in gate.add(bytes) },
            onClosed: { reason in
                gate.fail(CloudRelayTransportError.channelClosed(reason))
                if reason == .done {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: CloudRelayTransportError.channelClosed(reason))
                }
            }
        )
        let source = HttpResponseSource(channel: channel, frames: frames)
        do {
            try await channel.grantCredit(bytes: CloudRelayProxy.initialCreditBytes)
            try await sendRequestBody(request, channel: channel, gate: gate)
            let response = try await source.readHead(url: url)
            return (response, source)
        } catch {
            await source.finish(reason: .done)
            throw error
        }
    }

    /// Uploads the body as chunk frames and the terminating end frame, each
    /// gated on the machine's request-body window.
    private func sendRequestBody(
        _ request: URLRequest,
        channel: CloudRelayChannel,
        gate: CloudChannelCreditGate
    ) async throws {
        let encoder = JSONEncoder()
        func send(_ frame: ClientFrame) async throws {
            let payload = try encoder.encode(frame)
            try await gate.consume(
                CloudChannelCreditGate.sealedCost(plaintextBytes: payload.count, compressed: true))
            _ = try await channel.send(plaintext: payload)
        }
        if let body = request.httpBody, !body.isEmpty {
            var offset = body.startIndex
            while offset < body.endIndex {
                let end =
                    body.index(offset, offsetBy: Self.chunkSize, limitedBy: body.endIndex)
                    ?? body.endIndex
                try await send(
                    ClientFrame(
                        kind: "chunk",
                        data: CloudChannelCrypto.base64URLEncode(body[offset..<end])
                    ))
                offset = end
            }
        }
        try await send(ClientFrame(kind: "end"))
    }
}

/// Single-consumer pull surface over one http channel's machine frames:
/// `readHead` then `nextBodyChunk` until nil. Every consumed frame
/// replenishes the machine's window, so the machine reads its local response
/// exactly as fast as this side is pulled. @unchecked Sendable covers the
/// iterator handoff between the opening task and the body consumer — the
/// single-consumer contract (like a URLSession receive loop) makes the
/// accesses sequential.
final class HttpResponseSource: @unchecked Sendable {
    private let channel: CloudRelayChannel
    private var iterator: AsyncThrowingStream<CloudRelayRequestTransport.WireFrame, any Error>.Iterator
    private var finished = false

    init(
        channel: CloudRelayChannel,
        frames: AsyncThrowingStream<CloudRelayRequestTransport.WireFrame, any Error>
    ) {
        self.channel = channel
        iterator = frames.makeAsyncIterator()
    }

    func readHead(url: URL) async throws -> HTTPURLResponse {
        guard let wire = try await iterator.next() else {
            throw CloudRelayTransportError.channelClosed(nil)
        }
        try? await channel.grantCredit(bytes: wire.sealedBytes)
        guard wire.frame.kind == "head", let status = wire.frame.status,
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: wire.frame.headers ?? [:]
            )
        else { throw CloudRelayTransportError.invalidFrame }
        return response
    }

    /// The next decoded body chunk, or nil after the machine's end frame
    /// (which also closes the channel from this side).
    func nextBodyChunk() async throws -> Data? {
        while true {
            guard !finished else { return nil }
            guard let wire = try await iterator.next() else {
                throw CloudRelayTransportError.channelClosed(nil)
            }
            try? await channel.grantCredit(bytes: wire.sealedBytes)
            switch wire.frame.kind {
            case "chunk":
                guard let encoded = wire.frame.data,
                    let chunk = CloudChannelCrypto.base64URLDecode(encoded)
                else { throw CloudRelayTransportError.invalidFrame }
                if chunk.isEmpty { continue }
                return chunk
            case "end":
                await finish(reason: .done)
                return nil
            default:
                throw CloudRelayTransportError.invalidFrame
            }
        }
    }

    func finish(reason: CloudChannelCloseReason) async {
        guard !finished else { return }
        finished = true
        await channel.close(reason: reason)
    }
}
