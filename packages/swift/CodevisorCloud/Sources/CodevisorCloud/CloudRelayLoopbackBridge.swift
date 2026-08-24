import CodevisorClient
import Foundation
import Network

/// A real local address for one cloud machine. Every accepted loopback TCP
/// connection becomes one end-to-end encrypted, flow-controlled byte stream
/// to the machine's own Codevisor listener.
///
/// The bridge does not parse HTTP or WebSocket traffic. Request streaming,
/// chunked responses, MJPEG, upgrades, keep-alive, half-closes, and any future
/// protocol layered on TCP therefore retain their original wire semantics.
public final class CloudRelayLoopbackBridge: @unchecked Sendable {
    public enum BridgeError: Error, Sendable {
        case alreadyStarted
        case stopped
    }

    static let channelType = "byte-stream"
    static let service = "codevisor-loopback"
    static let protocolVersion = 1
    static let maximumChunkBytes = 64 * 1024
    static let initialCreditBytes = 1024 * 1024

    private let endpoint: any CloudChannelTransport
    private let queue = DispatchQueue(label: "com.codevisor.cloud-loopback-bridge")
    private let lock = NSLock()
    private var listener: NWListener?
    private var stopped = false
    private var connections: [ObjectIdentifier: LoopbackConnection] = [:]
    public private(set) var port: UInt16?

    public init(endpoint: any CloudChannelTransport) {
        self.endpoint = endpoint
    }

    /// Starts a loopback-only listener on an ephemeral port.
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
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, any Error>
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        result = .failure(BridgeError.stopped)
                        break
                    }
                    result = .success(port)
                case let .failed(error):
                    result = .failure(error)
                case .cancelled:
                    result = .failure(BridgeError.stopped)
                default:
                    return
                }
                guard once.claim() else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.port = port }
        Log.cloud.info(
            "Cloud loopback bridge for \(self.endpoint.machineDeviceId, privacy: .public) listening on 127.0.0.1:\(port)"
        )
        return port
    }

    /// Stops listening and tears down every active tunnel.
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

    /// Raw ChaCha20-Poly1305 box size: plaintext + 16-byte tag (the box
    /// travels as raw bytes — no encoding expansion).
    static func sealedByteCount(forPlaintextBytes count: Int) -> Int {
        precondition(count >= 0)
        return count + 16
    }

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
}

// MARK: - One accepted connection

private final class LoopbackConnection: @unchecked Sendable {
    private struct RelayChunk: Sendable {
        var data: Data
        var sealedBytes: Int
    }

    private enum TunnelError: Error {
        case relayClosed
        case creditOverflow
        case invalidCiphertextCost
    }

    private let connection: NWConnection
    private let endpoint: any CloudChannelTransport
    private let queue: DispatchQueue

    init(connection: NWConnection, endpoint: any CloudChannelTransport, queue: DispatchQueue) {
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

        let (inbound, inboundContinuation) = AsyncStream<RelayChunk>.makeStream()
        let (credits, creditContinuation) = AsyncStream<Int>.makeStream()
        let channel: CloudRelayChannel
        do {
            channel = try await endpoint.openFlowControlledChannel(
                channelType: CloudRelayLoopbackBridge.channelType,
                params: .object([
                    "service": .string(CloudRelayLoopbackBridge.service),
                    "version": .number(Double(CloudRelayLoopbackBridge.protocolVersion)),
                ]),
                onMessage: { data, sealedBytes in
                    inboundContinuation.yield(RelayChunk(data: data, sealedBytes: sealedBytes))
                },
                onCredit: { bytes in
                    creditContinuation.yield(bytes)
                },
                onClosed: { _ in
                    inboundContinuation.finish()
                    creditContinuation.finish()
                }
            )
        } catch {
            inboundContinuation.finish()
            creditContinuation.finish()
            return
        }

        do {
            try await channel.grantCredit(bytes: CloudRelayLoopbackBridge.initialCreditBytes)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.copyClientToMachine(channel: channel, credits: credits) }
                group.addTask { try await self.copyMachineToClient(channel: channel, inbound: inbound) }
                do {
                    while try await group.next() != nil {}
                } catch {
                    // Cancellation alone does not wake an outstanding
                    // NWConnection.receive; cancel the socket before the task
                    // group waits for its sibling to unwind.
                    connection.cancel()
                    group.cancelAll()
                    throw error
                }
            }
            await channel.close(reason: .done)
        } catch {
            await channel.close(reason: .rejected)
            Log.cloud.debug("Cloud byte tunnel ended: \(String(describing: error), privacy: .public)")
        }
        inboundContinuation.finish()
        creditContinuation.finish()
    }

    /// Local TCP → relay. Reading pauses before each chunk until the peer has
    /// granted enough ciphertext budget for the largest possible receive.
    private func copyClientToMachine(
        channel: CloudRelayChannel,
        credits: AsyncStream<Int>
    ) async throws {
        var available = 0
        var iterator = credits.makeAsyncIterator()
        let maximumCost = CloudRelayLoopbackBridge.sealedByteCount(
            forPlaintextBytes: CloudRelayLoopbackBridge.maximumChunkBytes
        )
        while true {
            try await fillCredit(&available, required: maximumCost, from: &iterator)
            let (data, complete) = try await receiveChunk()
            if let data, !data.isEmpty {
                let cost = try await channel.send(plaintext: data)
                guard
                    cost
                        == CloudRelayLoopbackBridge.sealedByteCount(
                            forPlaintextBytes: data.count
                        ),
                    cost <= available
                else { throw TunnelError.invalidCiphertextCost }
                available -= cost
            }
            if complete {
                let finCost = CloudRelayLoopbackBridge.sealedByteCount(forPlaintextBytes: 0)
                try await fillCredit(&available, required: finCost, from: &iterator)
                let actualCost = try await channel.send(plaintext: Data())
                guard actualCost == finCost, actualCost <= available else {
                    throw TunnelError.invalidCiphertextCost
                }
                return
            }
        }
    }

    /// Relay → local TCP. Credit is returned only after Network.framework has
    /// accepted each chunk, propagating local backpressure across the relay.
    private func copyMachineToClient(
        channel: CloudRelayChannel,
        inbound: AsyncStream<RelayChunk>
    ) async throws {
        for await chunk in inbound {
            if chunk.data.isEmpty {
                try await send(Data(), isComplete: true)
                try await channel.grantCredit(bytes: chunk.sealedBytes)
                return
            }
            try await send(chunk.data)
            try await channel.grantCredit(bytes: chunk.sealedBytes)
        }
        throw TunnelError.relayClosed
    }

    private func fillCredit(
        _ available: inout Int,
        required: Int,
        from iterator: inout AsyncStream<Int>.Iterator
    ) async throws {
        while available < required {
            guard let grant = await iterator.next(), grant > 0 else {
                throw TunnelError.relayClosed
            }
            guard available <= Int.max - grant else { throw TunnelError.creditOverflow }
            available += grant
        }
    }

    private func receiveChunk() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: CloudRelayLoopbackBridge.maximumChunkBytes
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private func send(_ data: Data, isComplete: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: isComplete && data.isEmpty ? nil : data,
                contentContext: isComplete ? .finalMessage : .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }
}
