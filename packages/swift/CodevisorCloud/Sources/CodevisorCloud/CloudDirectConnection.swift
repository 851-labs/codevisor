import ACPKit
import CodevisorClient
import Foundation

/// One direct LAN pipe to a single machine: the same sealed-channel protocol
/// as the cloud relay (hello/welcome, binary envelope batches, per-direction
/// seqs, negotiated compression, credit flow control) over a plain WebSocket
/// to the machine's own `/v1/direct` listener — no hub in the middle, so
/// frames make one LAN hop instead of a round trip through the relay region.
///
/// Deliberately simpler than `CloudHubConnection`: single-shot (no reconnect
/// loop — when the socket dies the pipe is done, its channels fail, and
/// `onDown` fires once so the selection layer falls back to the relay), no
/// resume, no presence. Identity comes from the same app device keys as the
/// relay; the machine refuses hellos from devices it has not already pinned
/// (TOFU happens on the relay, never here), and the E2E channel crypto
/// authenticates both ends of every frame, so the pipe needs no TLS.
public actor CloudDirectConnection {
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
    private let readyTimeout: Duration
    private let heartbeatInterval: Duration
    private let heartbeatTimeout: Duration
    /// Fires exactly once when the pipe dies for any reason other than
    /// `shutdown()` — the cue to route new channels over the relay again.
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
    /// When the outstanding keepalive ping left, for RTT measurement.
    private var pingSentAt: ContinuousClock.Instant?
    /// Direct-pipe round-trip time from the most recent keepalive ping/pong —
    /// path-latency observability, never used for routing decisions.
    public private(set) var lastRttMillis: Int?
    /// Serializes outbound writes so relay frames hit the wire in seq order
    /// even when several tasks send concurrently (same scheme as the hub).
    private var sendChain: Task<Void, Never> = Task {}
    private var channels: [String: ChannelState] = [:]

    private final class ChannelState {
        let cipher: CloudChannelCipher
        var nextOutboundSeq: UInt64
        var nextInboundSeq: UInt64 = 0
        let flowControlled: Bool
        let compressed: Bool
        var inboundCredit = 0
        let onMessage: @Sendable (Data, Int) -> Void
        let onCredit: @Sendable (Int) -> Void
        let onClosed: @Sendable (CloudChannelCloseReason?) -> Void

        init(
            cipher: CloudChannelCipher,
            nextOutboundSeq: UInt64,
            flowControlled: Bool,
            compressed: Bool,
            onMessage: @escaping @Sendable (Data, Int) -> Void,
            onCredit: @escaping @Sendable (Int) -> Void,
            onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
        ) {
            self.cipher = cipher
            self.nextOutboundSeq = nextOutboundSeq
            self.flowControlled = flowControlled
            self.compressed = compressed
            self.onMessage = onMessage
            self.onCredit = onCredit
            self.onClosed = onClosed
        }
    }

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
        onDown: (@Sendable () -> Void)? = nil
    ) {
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

    // MARK: Lifecycle

    /// Opens the socket and sends hello. Safe to call repeatedly; a dead pipe
    /// stays dead (build a new instance to try again).
    public func connect() {
        guard runTask == nil, !isDown else { return }
        runTask = Task { await run() }
    }

    /// Whether the pipe is welcomed and usable right now.
    public var isReady: Bool { isWelcomed && !isDown }

    /// Silent teardown by the owner: channels fail but `onDown` does not fire.
    public func shutdown() {
        onDown = nil
        runTask?.cancel()
        goDown()
    }

    /// Waits until the machine has welcomed this pipe (bounded by the ready
    /// timeout), starting the connection if needed.
    public func waitUntilReady() async throws {
        guard !isDown else { throw CloudHubConnectionError.disconnected }
        connect()
        if isWelcomed { return }
        let id = waiterSeq
        waiterSeq += 1
        let timeout = readyTimeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expireWaiter(id: id)
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters[id] = continuation
        }
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
                Log.cloud.info(
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

    // MARK: Wire

    private struct HelloMessage: Encodable {
        struct Device: Encodable {
            var deviceId: String
            var kind = "app"
            var name: String
            var os: String
            var appVersion: String?
            var publicKey: String
        }

        var t = "hello"
        var protocolVersion = CloudDirectConnection.protocolVersion
        var device: Device

        enum CodingKeys: String, CodingKey {
            case t
            case protocolVersion = "protocol"
            case device
        }
    }

    private struct RelayHeader: Codable {
        var machineId: String
        var frame: CloudRelayFrame
    }

    private struct TypeProbe: Decodable {
        var t: String
    }

    private func sendHello(identity: CloudAppDeviceIdentity) throws {
        let hello = HelloMessage(
            device: HelloMessage.Device(
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
                guard let relay = try? decoder.decode(RelayHeader.self, from: envelope.header),
                    relay.machineId == machineDeviceId
                else { continue }
                handleRelay(relay.frame, payload: envelope.payload)
            }
        case let .string(text):
            guard let probe = try? decoder.decode(TypeProbe.self, from: Data(text.utf8)) else {
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
                if let pingSentAt {
                    lastRttMillis = Int(pingSentAt.duration(to: .now) / .milliseconds(1))
                    self.pingSentAt = nil
                }
                pongDeadlineTask?.cancel()
                pongDeadlineTask = nil
            default:
                break
            }
        }
    }

    // MARK: Keepalive

    /// The LAN heartbeat is deliberately tighter than the hub's: a dead
    /// direct pipe should demote to the relay within seconds, not half a
    /// minute of a user staring at a stalled stream.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, heartbeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeatInterval)
                guard !Task.isCancelled, let self else { return }
                await self.sendKeepalivePing()
            }
        }
    }

    private func sendKeepalivePing() {
        // A pending deadline means the last ping is still unanswered: don't
        // send another (which would keep resetting the deadline forever on a
        // half-open socket) — let the deadline decide.
        guard isWelcomed, !isDown, pongDeadlineTask == nil else { return }
        struct Ping: Encodable {
            var t = "ping"
        }
        pongDeadlineTask = Task { [weak self, heartbeatTimeout] in
            try? await Task.sleep(for: heartbeatTimeout)
            guard !Task.isCancelled else { return }
            await self?.expireHeartbeat()
        }
        pingSentAt = .now
        do {
            try enqueueSend(.string(String(decoding: try encoder.encode(Ping()), as: UTF8.self)))
        } catch {
            goDown()
        }
    }

    private func expireHeartbeat() {
        guard !isDown, pongDeadlineTask != nil else { return }
        Log.cloud.info(
            "Direct pipe to \(self.machineDeviceId, privacy: .public) missed its pong deadline")
        goDown()
    }

    func sendRelay(frame: CloudRelayFrame, payload: Data = Data()) throws {
        let header = try encoder.encode(RelayHeader(machineId: machineDeviceId, frame: frame))
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
}

// MARK: - Inbound relay frames

extension CloudDirectConnection {
    private func handleRelay(_ frame: CloudRelayFrame, payload: Data) {
        guard let state = channels[frame.channelId] else { return }
        // Per-direction seqs are strictly monotonic from 0; a gap or repeat
        // is a protocol error and kills the channel.
        guard frame.seq == state.nextInboundSeq else {
            abortChannel(frame.channelId, reason: .protocolError)
            return
        }
        state.nextInboundSeq += 1
        switch frame {
        case .open:
            // Machines never open channels toward the app.
            abortChannel(frame.channelId, reason: .protocolError)
        case let .data(channelId, seq):
            do {
                var plaintext = try state.cipher.open(
                    payload,
                    channelId: channelId,
                    direction: .responderToOpener,
                    seq: seq
                )
                if state.compressed {
                    plaintext = try Self.unframe(plaintext)
                }
                let sealedBytes = payload.count
                if state.flowControlled {
                    guard sealedBytes <= state.inboundCredit else {
                        abortChannel(channelId, reason: .protocolError)
                        return
                    }
                    state.inboundCredit -= sealedBytes
                }
                state.onMessage(plaintext, sealedBytes)
                // No auto-replenish (see CloudHubConnection+Inbound).
            } catch {
                abortChannel(channelId, reason: .cryptoError)
            }
        case let .credit(channelId, _, bytes):
            guard bytes > 0 else {
                abortChannel(channelId, reason: .protocolError)
                return
            }
            state.onCredit(bytes)
        case let .close(channelId, _, reason):
            channels.removeValue(forKey: channelId)
            state.onClosed(reason)
        }
    }

    /// Strips the negotiated framing byte, inflating DEFLATE bodies.
    private static func unframe(_ plaintext: Data) throws -> Data {
        guard let framing = plaintext.first else { throw CloudDeflateError.corruptInput }
        let body = plaintext.dropFirst()
        switch framing {
        case CloudDeflate.framingRaw: return Data(body)
        case CloudDeflate.framingDeflate: return try CloudDeflate.inflate(Data(body))
        default: throw CloudDeflateError.corruptInput
        }
    }

}

// MARK: - Channels

extension CloudDirectConnection {

    /// Opens an end-to-end encrypted channel over this pipe — same semantics
    /// as `CloudHubConnection.openChannel`.
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

    /// Opens a raw channel with explicit credit-based flow control — same
    /// semantics as `CloudHubConnection.openFlowControlledChannel`.
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
        let state = ChannelState(
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
}

// MARK: - CloudChannelHosting

extension CloudDirectConnection: CloudChannelHosting {
    func send(channelId: String, plaintext: Data) throws -> Int {
        guard let state = channels[channelId] else {
            throw CloudHubConnectionError.channelClosed
        }
        guard isWelcomed, !isDown else { throw CloudHubConnectionError.disconnected }
        let seq = state.nextOutboundSeq
        state.nextOutboundSeq += 1
        let body = state.compressed ? Data([CloudDeflate.framingRaw]) + plaintext : plaintext
        let sealed = try state.cipher.seal(
            body,
            channelId: channelId,
            direction: .openerToResponder,
            seq: seq
        )
        try sendRelay(frame: .data(channelId: channelId, seq: seq), payload: sealed)
        return sealed.count
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

    /// Closes a channel from this side. `onClosed` is not invoked for
    /// self-initiated closes.
    func closeChannel(_ channelId: String, reason: CloudChannelCloseReason) {
        guard let state = channels.removeValue(forKey: channelId) else { return }
        let seq = state.nextOutboundSeq
        state.nextOutboundSeq += 1
        try? sendRelay(frame: .close(channelId: channelId, seq: seq, reason: reason))
    }

    private func abortChannel(_ channelId: String, reason: CloudChannelCloseReason) {
        guard let state = channels.removeValue(forKey: channelId) else { return }
        let seq = state.nextOutboundSeq
        state.nextOutboundSeq += 1
        try? sendRelay(frame: .close(channelId: channelId, seq: seq, reason: reason))
        state.onClosed(reason)
    }
}
