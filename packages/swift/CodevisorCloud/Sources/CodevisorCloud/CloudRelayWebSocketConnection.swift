import ACPKit
import CodevisorClient
import Foundation

/// Tunnels WebSocket connections through a flow-controlled "ws" relay
/// channel — the socket sibling of `CloudRelayRequestTransport`, used for
/// event streams and terminals.
public struct CloudRelayWebSocketTransport: ServerWebSocketTransport {
    private let endpoint: any CloudChannelTransport

    public init(endpoint: any CloudChannelTransport) {
        self.endpoint = endpoint
    }

    public func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
        CloudRelayWebSocketConnection(endpoint: endpoint, request: request)
    }
}

/// One relayed WebSocket: lazily opens a "ws" channel for the request's path
/// and adapts `{kind: text|binary}` frames to `ServerWebSocketMessage`.
/// Flow control is consumer-paced both ways: outbound sends gate on the
/// machine's grants, and the machine's window replenishes only as `receive`
/// actually consumes messages — a slow app stalls the machine's local socket
/// instead of ballooning buffers on any hop. Single-consumer, like a
/// URLSessionWebSocketTask receive loop.
final class CloudRelayWebSocketConnection: ServerWebSocketConnecting, @unchecked Sendable {
    private struct WsFrame: Codable {
        var kind: String
        var data: String
    }

    private struct Inbound {
        var message: ServerWebSocketMessage
        /// Ciphertext bytes to replenish once the consumer has this message.
        var credit: Int
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

    /// Immediate (non-consumer-paced) grants — `part` frames and skipped
    /// unknown kinds — accumulate here until the channel handle exists, so a
    /// frame racing the open's return can never leak window.
    private final class ImmediateGrants: @unchecked Sendable {
        private let lock = NSLock()
        private var channel: CloudRelayChannel?
        private var pending = 0

        func attach(_ channel: CloudRelayChannel) {
            lock.withLock { self.channel = channel }
            flush()
        }

        func grant(_ bytes: Int) {
            lock.withLock { pending += bytes }
            flush()
        }

        private func flush() {
            let drained: (channel: CloudRelayChannel, bytes: Int)? = lock.withLock {
                guard let channel, pending > 0 else { return nil }
                defer { pending = 0 }
                return (channel, pending)
            }
            guard let drained else { return }
            Task { try? await drained.channel.grantCredit(bytes: drained.bytes) }
        }
    }

    private let lock = NSLock()
    private let openTask: Task<CloudRelayChannel, any Error>
    private let gate = CloudChannelCreditGate()
    private var iterator: AsyncThrowingStream<Inbound, any Error>.Iterator
    private var cancelled = false

    init(endpoint: any CloudChannelTransport, request: URLRequest) {
        let (messages, continuation) = AsyncThrowingStream<Inbound, any Error>.makeStream()
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
        let immediate = ImmediateGrants()
        let gate = gate
        openTask = Task {
            let channel = try await endpoint.openFlowControlledChannel(
                channelType: "ws",
                params: .object(["path": .string(path)]),
                compressed: true,
                onMessage: { data, sealedBytes in
                    guard let frame = try? decoder.decode(WsFrame.self, from: data) else {
                        continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                        return
                    }
                    switch frame.kind {
                    case "text":
                        continuation.yield(Inbound(message: .string(frame.data), credit: sealedBytes))
                    case "binary":
                        if let decoded = CloudChannelCrypto.base64URLDecode(frame.data) {
                            continuation.yield(Inbound(message: .data(decoded), credit: sealedBytes))
                        } else {
                            continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                        }
                    case "part":
                        // Slices replenish immediately: the reassembly buffer
                        // is bounded by one message, and holding the window
                        // hostage to a half-arrived message would deadlock it.
                        if pendingParts.append(base64URL: frame.data) {
                            immediate.grant(sealedBytes)
                        } else {
                            continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                        }
                    case "text-end":
                        if let message = pendingParts.finish(base64URL: frame.data) {
                            continuation.yield(
                                Inbound(
                                    message: .string(String(decoding: message, as: UTF8.self)),
                                    credit: sealedBytes
                                ))
                        } else {
                            continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                        }
                    case "binary-end":
                        if let message = pendingParts.finish(base64URL: frame.data) {
                            continuation.yield(Inbound(message: .data(message), credit: sealedBytes))
                        } else {
                            continuation.finish(throwing: CloudRelayTransportError.invalidFrame)
                        }
                    default:
                        // Future kinds are skipped, but their cost must not
                        // leak out of the machine's window.
                        immediate.grant(sealedBytes)
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
            immediate.attach(channel)
            try await channel.grantCredit(bytes: CloudRelayProxy.initialCreditBytes)
            return channel
        }
    }

    func send(_ message: ServerWebSocketMessage) async throws {
        let channel = try await openTask.value
        let frame =
            switch message {
            case let .string(text):
                WsFrame(kind: "text", data: text)
            case let .data(data):
                WsFrame(kind: "binary", data: CloudChannelCrypto.base64URLEncode(data))
            }
        let payload = try JSONEncoder().encode(frame)
        try await gate.consume(
            CloudChannelCreditGate.sealedCost(plaintextBytes: payload.count, compressed: true))
        _ = try await channel.send(plaintext: payload)
    }

    func receive() async throws -> ServerWebSocketMessage {
        // Ensure the channel is (being) opened before waiting for frames.
        let channel = try await openTask.value
        guard let inbound = try await iterator.next() else {
            // The peer finished cleanly; a socket consumer expects a throw
            // (like URLSession's receive on a closed socket) to trigger its
            // reconnect/teardown path.
            throw CloudRelayTransportError.channelClosed(.done)
        }
        // Consumed: the machine may now put this many bytes back in flight.
        try? await channel.grantCredit(bytes: inbound.credit)
        return inbound.message
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
