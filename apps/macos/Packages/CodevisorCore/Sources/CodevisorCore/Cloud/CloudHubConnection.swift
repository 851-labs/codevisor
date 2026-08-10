import ACPKit
import Foundation

// MARK: - Wire protocol (packages/api/src/cloud-protocol.ts, app plane)

/// Why a relay channel ended, as carried in `close` frames.
public enum CloudChannelCloseReason: String, Codable, Sendable {
    case done
    case rejected
    case unsupported
    case peerDisconnected = "peer-disconnected"
    case protocolError = "protocol-error"
    case cryptoError = "crypto-error"
}

/// A ChaCha20-Poly1305 box (base64url ciphertext ‖ tag).
public struct CloudSealedPayload: Codable, Sendable, Equatable {
    public var box: String

    public init(box: String) {
        self.box = box
    }
}

/// One frame of a relay channel. The hub never parses payloads; `channelType`
/// itself lives inside the sealed open payload.
public enum CloudRelayFrame: Sendable, Equatable {
    case open(channelId: String, seq: UInt64, ephemeralKey: String, sealed: CloudSealedPayload)
    case data(channelId: String, seq: UInt64, sealed: CloudSealedPayload)
    case credit(channelId: String, seq: UInt64, bytes: Int)
    case close(channelId: String, seq: UInt64, reason: CloudChannelCloseReason)

    public var channelId: String {
        switch self {
        case let .open(channelId, _, _, _), let .data(channelId, _, _),
             let .credit(channelId, _, _), let .close(channelId, _, _):
            channelId
        }
    }

    public var seq: UInt64 {
        switch self {
        case let .open(_, seq, _, _), let .data(_, seq, _),
             let .credit(_, seq, _), let .close(_, seq, _):
            seq
        }
    }
}

extension CloudRelayFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, channelId, seq, ephemeralKey, sealed, bytes, reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        let channelId = try container.decode(String.self, forKey: .channelId)
        let seq = try container.decode(UInt64.self, forKey: .seq)
        switch type {
        case "open":
            self = .open(
                channelId: channelId,
                seq: seq,
                ephemeralKey: try container.decode(String.self, forKey: .ephemeralKey),
                sealed: try container.decode(CloudSealedPayload.self, forKey: .sealed)
            )
        case "data":
            self = .data(
                channelId: channelId,
                seq: seq,
                sealed: try container.decode(CloudSealedPayload.self, forKey: .sealed)
            )
        case "credit":
            self = .credit(
                channelId: channelId,
                seq: seq,
                bytes: try container.decode(Int.self, forKey: .bytes)
            )
        case "close":
            self = .close(
                channelId: channelId,
                seq: seq,
                reason: try container.decode(CloudChannelCloseReason.self, forKey: .reason)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .t, in: container, debugDescription: "Unknown relay frame type \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(channelId, forKey: .channelId)
        try container.encode(seq, forKey: .seq)
        switch self {
        case let .open(_, _, ephemeralKey, sealed):
            try container.encode("open", forKey: .t)
            try container.encode(ephemeralKey, forKey: .ephemeralKey)
            try container.encode(sealed, forKey: .sealed)
        case let .data(_, _, sealed):
            try container.encode("data", forKey: .t)
            try container.encode(sealed, forKey: .sealed)
        case let .credit(_, _, bytes):
            try container.encode("credit", forKey: .t)
            try container.encode(bytes, forKey: .bytes)
        case let .close(_, _, reason):
            try container.encode("close", forKey: .t)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// Errors the hub connection can surface to channel openers.
public enum CloudHubConnectionError: Error, Equatable, Sendable, LocalizedError {
    /// The hub closed the socket with a fatal code (4200 bad token, 4201
    /// unsupported protocol) — reconnecting cannot help.
    case rejected(closeCode: Int)
    case notSignedIn
    case credentialsUnavailable
    case machineUnavailable
    case disconnected
    case timedOut
    case channelClosed

    public var errorDescription: String? {
        switch self {
        case let .rejected(code):
            "Codevisor Cloud rejected the connection (code \(code)). Sign in again."
        case .notSignedIn:
            "Not signed in to Codevisor Cloud."
        case .credentialsUnavailable:
            "Codevisor couldn't load its cloud credentials."
        case .machineUnavailable:
            "The cloud machine is offline."
        case .disconnected:
            "The Codevisor Cloud connection is offline."
        case .timedOut:
            "Timed out connecting to Codevisor Cloud."
        case .channelClosed:
            "The relay channel is closed."
        }
    }
}

// MARK: - Hub connection

/// The app's one WebSocket to its Codevisor Cloud hub: hello/welcome handshake,
/// presence, and multiplexed end-to-end encrypted relay channels to machines.
/// The app is always the channel opener; per-direction sequence numbers start
/// at 0 and the responder direction is enforced monotonic here.
///
/// Reconnects with jittered exponential backoff; hub close codes 4200/4201
/// are fatal (revoked token / unsupported protocol) and stop the loop.
/// Channels are ephemeral: they die with either WebSocket and openers
/// re-establish what they need after reconnect.
public actor CloudHubConnection {
    public static let protocolVersion = 1
    static let maximumMessageSize = 16 * 1024 * 1024
    static let fatalCloseCodes: Set<Int> = [4200, 4201]

    private let serverURL: URL
    private let credentialStore: any CloudCredentialStore
    private let webSocketTransport: any ServerWebSocketTransport
    private let deviceName: String
    private let deviceOS: String
    private let appVersion: String?
    private let readyTimeout: Duration
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var runTask: Task<Void, Never>?
    private var socket: (any ServerWebSocketConnecting)?
    private var isWelcomed = false
    private var fatalFailure: CloudHubConnectionError?
    private var waiterSeq = 0
    private var readyWaiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var machineWaiterSeq = 0
    private var machineOnlineWaiters: [Int: (machineId: String, continuation: CheckedContinuation<Void, any Error>)] = [:]
    private var channels: [String: ChannelState] = [:]
    /// Keychain-backed values are immutable for this hub's lifetime. The
    /// account controller destroys the hub on sign-out/server switch, so no
    /// channel or reconnect should ever return to the credential store.
    private var cachedSessionToken: Result<String, CloudHubConnectionError>?
    private var cachedIdentity: Result<CloudAppDeviceIdentity, CloudHubConnectionError>?
    /// Serializes outbound socket writes so relay frames hit the wire in seq
    /// order even when several tasks send concurrently.
    private var sendChain: Task<Void, Never> = Task {}
    /// The machine presence list from welcome, kept fresh by presence frames.
    public private(set) var machines: [CloudMachine] = []

    private final class ChannelState {
        let machineDeviceId: String
        let cipher: CloudChannelCipher
        var nextOutboundSeq: UInt64
        var nextInboundSeq: UInt64 = 0
        let onMessage: @Sendable (Data) -> Void
        let onClosed: @Sendable (CloudChannelCloseReason?) -> Void

        init(
            machineDeviceId: String,
            cipher: CloudChannelCipher,
            nextOutboundSeq: UInt64,
            onMessage: @escaping @Sendable (Data) -> Void,
            onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
        ) {
            self.machineDeviceId = machineDeviceId
            self.cipher = cipher
            self.nextOutboundSeq = nextOutboundSeq
            self.onMessage = onMessage
            self.onClosed = onClosed
        }
    }

    public init(
        serverURL: URL,
        credentialStore: any CloudCredentialStore,
        deviceName: String = CloudHubConnection.defaultDeviceName,
        deviceOS: String = CloudHubConnection.defaultDeviceOS,
        appVersion: String? = nil,
        webSocketTransport: any ServerWebSocketTransport = URLSessionWebSocketTransport(),
        readyTimeout: Duration = .seconds(15)
    ) {
        self.serverURL = serverURL
        self.credentialStore = credentialStore
        self.deviceName = deviceName
        self.deviceOS = deviceOS
        self.appVersion = appVersion
        self.webSocketTransport = webSocketTransport
        self.readyTimeout = readyTimeout
    }

    public static var defaultDeviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    public static var defaultDeviceOS: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        "iOS"
        #else
        "unknown"
        #endif
    }

    // MARK: Lifecycle

    /// Starts the connection loop if it isn't already running. Safe to call
    /// repeatedly.
    public func connect() {
        guard runTask == nil, fatalFailure == nil else { return }
        runTask = Task { await run() }
    }

    /// Tears everything down (sign-out / server switch). The instance is done
    /// after this — a new sign-in builds a new connection.
    public func shutdown() {
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isWelcomed = false
        failAllChannels()
        failWaiters(with: CloudHubConnectionError.disconnected)
        failMachineWaiters(with: CloudHubConnectionError.disconnected)
    }

    /// Waits until the hub has welcomed this connection (bounded by the ready
    /// timeout), starting the loop if needed.
    public func waitUntilReady() async throws {
        connect()
        if isWelcomed { return }
        if let fatalFailure { throw fatalFailure }
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
        var failures = 0
        while !Task.isCancelled, fatalFailure == nil {
            do {
                let token = try sessionToken()
                let identity = try appDeviceIdentity()
                var request = URLRequest(url: try connectURL(token: token))
                // The query token is the sole credential. Never let a stale
                // session cookie from the shared jar ride along — if the hub
                // honored it over the token, this device would silently join
                // the wrong account.
                request.httpShouldHandleCookies = false
                Log.cloud.info("Connecting to cloud hub at \(self.serverURL.host() ?? "?", privacy: .public)")
                let socket = webSocketTransport.connect(
                    request,
                    maximumMessageSize: Self.maximumMessageSize
                )
                self.socket = socket
                try sendHello(identity: identity)
                // Keepalive: Cloudflare's edge (and local workerd) closes
                // idle WebSockets after ~100s, and URLSessionWebSocketTask
                // sends nothing on its own — so an app that sat idle would
                // find a dead hub the moment the user picks a machine.
                // Protocol pings are answered by the hub's auto-response
                // without even waking the Durable Object.
                let keepalive = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { return }
                        await self?.sendKeepalivePing()
                    }
                }
                defer { keepalive.cancel() }
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    await handle(message)
                    if isWelcomed { failures = 0 }
                }
            } catch let error as CloudHubConnectionError
                where error == .notSignedIn || error == .credentialsUnavailable {
                // Credential failures cannot be repaired by reconnecting this
                // hub. A sign-in/retry creates a fresh instance.
                becomeFatal(error)
            } catch {
                if !Task.isCancelled {
                    Log.cloud.error("Cloud hub connection failed: \(String(describing: error), privacy: .public)")
                }
            }
            let closeCode = socket?.closeCode.rawValue ?? 0
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            isWelcomed = false
            failAllChannels()
            if Self.fatalCloseCodes.contains(closeCode) {
                becomeFatal(.rejected(closeCode: closeCode))
            }
            guard fatalFailure == nil, !Task.isCancelled else { break }
            failures += 1
            // Same curve as the other sockets: 250ms · 2^n capped at 5s + jitter.
            let base = min(5_000, 250 * (1 << min(failures, 5)))
            try? await Task.sleep(for: .milliseconds(base + Int.random(in: 0...250)))
        }
    }

    private func becomeFatal(_ failure: CloudHubConnectionError) {
        guard fatalFailure == nil else { return }
        Log.cloud.error("Cloud hub connection is fatal: \(String(describing: failure), privacy: .public)")
        fatalFailure = failure
        failWaiters(with: failure)
        failMachineWaiters(with: failure)
    }

    private func failWaiters(with error: any Error) {
        let waiters = readyWaiters.values
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func failMachineWaiters(with error: any Error) {
        let waiters = machineOnlineWaiters.values
        machineOnlineWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func sessionToken() throws -> String {
        if let cachedSessionToken { return try cachedSessionToken.get() }
        let result: Result<String, CloudHubConnectionError>
        do {
            if let token = try credentialStore.token(), !token.isEmpty {
                result = .success(token)
            } else {
                result = .failure(.notSignedIn)
            }
        } catch {
            Log.cloud.error("Cloud session credential load failed: \(String(describing: error), privacy: .public)")
            result = .failure(.credentialsUnavailable)
        }
        cachedSessionToken = result
        return try result.get()
    }

    private func appDeviceIdentity() throws -> CloudAppDeviceIdentity {
        if let cachedIdentity { return try cachedIdentity.get() }
        let result: Result<CloudAppDeviceIdentity, CloudHubConnectionError>
        do {
            result = .success(try credentialStore.ensureAppDeviceIdentity())
        } catch {
            Log.cloud.error("Cloud device credential load failed: \(String(describing: error), privacy: .public)")
            result = .failure(.credentialsUnavailable)
        }
        cachedIdentity = result
        return try result.get()
    }

    /// An offline machine is a state transition, not a timer-based connection
    /// failure. Park channel openers until presence says it is back instead of
    /// letting every event stream and terminal create an independent retry
    /// loop. Cancellation removes the parked request promptly.
    private func waitUntilMachineOnline(_ machineId: String) async throws {
        guard let machine = machines.first(where: { $0.deviceId == machineId }) else {
            throw CloudHubConnectionError.machineUnavailable
        }
        if machine.online { return }
        if Task.isCancelled { throw CancellationError() }

        let id = machineWaiterSeq
        machineWaiterSeq += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = withUnsafeCurrentTask { $0?.isCancelled ?? false }
                guard !cancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                machineOnlineWaiters[id] = (machineId, continuation)
            }
        } onCancel: {
            Task { await self.cancelMachineWaiter(id) }
        }
    }

    private func cancelMachineWaiter(_ id: Int) {
        machineOnlineWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func resumeMachineWaiters(for machineId: String) {
        let ready = machineOnlineWaiters.filter { $0.value.machineId == machineId }
        for (id, waiter) in ready {
            machineOnlineWaiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    private func failAllChannels() {
        let open = channels.values
        channels.removeAll()
        for channel in open {
            channel.onClosed(nil)
        }
    }

    /// RFC 3986 unreserved characters — everything else in the token is
    /// percent-encoded so it survives the hub's WHATWG query parsing.
    private static let tokenQueryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private func connectURL(token: String) throws -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw CloudHubConnectionError.disconnected
        }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = "\(basePath)/connect"
        // URLComponents.queryItems leaves "+" (and "/", "=") literal, but the
        // hub reads the query per the WHATWG URL standard, where "+" decodes
        // to a space. A session token containing "+" arrived corrupted, the
        // bearer lookup failed, and the connection either got rejected or —
        // worse — fell back to a stale session cookie in the shared cookie
        // jar and joined the wrong account's hub. Encode strictly so the
        // token round-trips verbatim.
        guard let encoded = token.addingPercentEncoding(withAllowedCharacters: Self.tokenQueryAllowed) else {
            throw CloudHubConnectionError.disconnected
        }
        components.percentEncodedQueryItems = [URLQueryItem(name: "token", value: encoded)]
        guard let url = components.url else { throw CloudHubConnectionError.disconnected }
        return url
    }

    // MARK: Outbound

    private struct HelloMessage: Encodable {
        struct Device: Encodable {
            var deviceId: String
            var kind: String
            var name: String
            var os: String
            var appVersion: String?
            var publicKey: String
        }

        var t = "hello"
        var protocolVersion = CloudHubConnection.protocolVersion
        var device: Device

        enum CodingKeys: String, CodingKey {
            case t
            case protocolVersion = "protocol"
            case device
        }
    }

    private struct RelayMessage: Encodable {
        var t = "relay"
        var machineId: String
        var frame: CloudRelayFrame
    }

    private func sendHello(identity: CloudAppDeviceIdentity) throws {
        let hello = HelloMessage(device: HelloMessage.Device(
            deviceId: identity.deviceId,
            kind: "app",
            name: deviceName,
            os: deviceOS,
            appVersion: appVersion,
            publicKey: identity.publicKey
        ))
        try enqueueSend(hello)
    }

    /// Best-effort protocol ping; a send failure here is the receive loop's
    /// problem to notice (it will throw and reconnect).
    private func sendKeepalivePing() {
        struct Ping: Encodable {
            var t = "ping"
        }
        try? enqueueSend(Ping())
    }

    private func sendRelay(machineId: String, frame: CloudRelayFrame) throws {
        guard socket != nil else { throw CloudHubConnectionError.disconnected }
        try enqueueSend(RelayMessage(machineId: machineId, frame: frame))
    }

    /// Chained sends keep wire order aligned with seq allocation order —
    /// concurrent senders must not overtake each other between allocating a
    /// seq and the frame reaching the socket.
    private func enqueueSend(_ message: some Encodable) throws {
        guard let socket else { throw CloudHubConnectionError.disconnected }
        let text = String(decoding: try encoder.encode(message), as: UTF8.self)
        sendChain = Task { [previous = sendChain] in
            await previous.value
            try? await socket.send(.string(text))
        }
    }

    // MARK: Channels

    /// Opens an end-to-end encrypted channel to a machine. `onMessage` gets
    /// each decrypted inbound payload; `onClosed` fires once when the channel
    /// ends (with the peer's close reason, or nil on connection loss). Both
    /// may be invoked before this returns.
    public func openChannel(
        machineDeviceId: String,
        machinePublicKey: String,
        channelType: String,
        params: JSONValue?,
        onMessage: @escaping @Sendable (Data) -> Void,
        onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
    ) async throws -> CloudRelayChannel {
        try await waitUntilReady()
        try await waitUntilMachineOnline(machineDeviceId)
        let identity = try appDeviceIdentity()
        let opened = try CloudChannelCrypto.openChannel(
            openerSecretKey: identity.secretKey,
            responderPublicKey: machinePublicKey
        )
        let channelId = UUID().uuidString.lowercased()
        var payload: [String: JSONValue] = ["channelType": .string(channelType)]
        if let params {
            payload["params"] = params
        }
        let plaintext = try encoder.encode(JSONValue.object(payload))
        let sealed = try opened.cipher.seal(
            plaintext,
            channelId: channelId,
            direction: .openerToResponder,
            seq: 0
        )
        let state = ChannelState(
            machineDeviceId: machineDeviceId,
            cipher: opened.cipher,
            nextOutboundSeq: 1,
            onMessage: onMessage,
            onClosed: onClosed
        )
        channels[channelId] = state
        do {
            try sendRelay(machineId: machineDeviceId, frame: .open(
                channelId: channelId,
                seq: 0,
                ephemeralKey: opened.ephemeralPublicKey,
                sealed: CloudSealedPayload(box: sealed)
            ))
        } catch {
            channels.removeValue(forKey: channelId)
            throw error
        }
        return CloudRelayChannel(id: channelId, hub: self)
    }

    func send(channelId: String, plaintext: Data) throws {
        guard let state = channels[channelId] else {
            throw CloudHubConnectionError.channelClosed
        }
        let seq = state.nextOutboundSeq
        state.nextOutboundSeq += 1
        let sealed = try state.cipher.seal(
            plaintext,
            channelId: channelId,
            direction: .openerToResponder,
            seq: seq
        )
        try sendRelay(machineId: state.machineDeviceId, frame: .data(
            channelId: channelId,
            seq: seq,
            sealed: CloudSealedPayload(box: sealed)
        ))
    }

    /// Closes a channel from this side. `onClosed` is not invoked for
    /// self-initiated closes.
    func closeChannel(_ channelId: String, reason: CloudChannelCloseReason) {
        guard let state = channels.removeValue(forKey: channelId) else { return }
        let seq = state.nextOutboundSeq
        state.nextOutboundSeq += 1
        try? sendRelay(machineId: state.machineDeviceId, frame: .close(
            channelId: channelId,
            seq: seq,
            reason: reason
        ))
    }

    /// Aborts a misbehaving channel: notifies the peer and the local owner.
    private func abortChannel(_ channelId: String, reason: CloudChannelCloseReason) {
        guard let state = channels.removeValue(forKey: channelId) else { return }
        let seq = state.nextOutboundSeq
        state.nextOutboundSeq += 1
        try? sendRelay(machineId: state.machineDeviceId, frame: .close(
            channelId: channelId,
            seq: seq,
            reason: reason
        ))
        state.onClosed(reason)
    }

    // MARK: Inbound

    private struct TypeProbe: Decodable {
        var t: String
    }

    private struct WelcomeMessage: Decodable {
        var connectionId: String
        var machines: [CloudMachine]
    }

    private struct PresenceMessage: Decodable {
        var machine: CloudMachine
    }

    private struct InboundRelayMessage: Decodable {
        var machineId: String
        var frame: CloudRelayFrame
    }

    private struct ErrorMessage: Decodable {
        var code: String
        var message: String
        var machineId: String?
        var channelId: String?
    }

    private func handle(_ message: ServerWebSocketMessage) async {
        let data: Data
        switch message {
        case let .data(payload):
            data = payload
        case let .string(text):
            data = Data(text.utf8)
        }
        guard let probe = try? decoder.decode(TypeProbe.self, from: data) else { return }
        switch probe.t {
        case "welcome":
            guard let welcome = try? decoder.decode(WelcomeMessage.self, from: data) else { return }
            Log.cloud.info("Cloud hub welcomed this device (\(welcome.machines.count) machines)")
            machines = welcome.machines
            for machine in welcome.machines where machine.online {
                resumeMachineWaiters(for: machine.deviceId)
            }
            isWelcomed = true
            let waiters = readyWaiters.values
            readyWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        case "presence":
            guard let presence = try? decoder.decode(PresenceMessage.self, from: data) else { return }
            if let index = machines.firstIndex(where: { $0.deviceId == presence.machine.deviceId }) {
                machines[index] = presence.machine
            } else {
                machines.append(presence.machine)
            }
            if presence.machine.online {
                resumeMachineWaiters(for: presence.machine.deviceId)
            }
        case "relay":
            guard let relay = try? decoder.decode(InboundRelayMessage.self, from: data) else { return }
            handleRelay(relay.frame)
        case "error":
            guard let failure = try? decoder.decode(ErrorMessage.self, from: data) else { return }
            Log.cloud.error(
                """
                Cloud hub error \(failure.code, privacy: .public): \(failure.message, privacy: .public) \
                (machine \(failure.machineId ?? "-", privacy: .public), channel \(failure.channelId ?? "-", privacy: .public))
                """
            )
            if let channelId = failure.channelId {
                channels.removeValue(forKey: channelId)?.onClosed(nil)
            } else if let machineId = failure.machineId {
                let affected = channels.filter { $0.value.machineDeviceId == machineId }
                for (id, state) in affected {
                    channels.removeValue(forKey: id)
                    state.onClosed(nil)
                }
            }
        default:
            // pong and future message kinds.
            break
        }
    }

    private func handleRelay(_ frame: CloudRelayFrame) {
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
        case let .data(channelId, seq, sealed):
            do {
                let plaintext = try state.cipher.open(
                    sealed.box,
                    channelId: channelId,
                    direction: .responderToOpener,
                    seq: seq
                )
                state.onMessage(plaintext)
                // Replenish the peer's flow-control window as we consume.
                let creditSeq = state.nextOutboundSeq
                state.nextOutboundSeq += 1
                try? sendRelay(machineId: state.machineDeviceId, frame: .credit(
                    channelId: channelId,
                    seq: creditSeq,
                    bytes: sealed.box.utf8.count
                ))
            } catch {
                abortChannel(channelId, reason: .cryptoError)
            }
        case .credit:
            // Inbound credit grants budget for our sends; sends are currently
            // small enough (chunked request bodies, input frames) that the
            // initial window suffices, so grants are accepted silently.
            break
        case let .close(channelId, _, reason):
            channels.removeValue(forKey: channelId)
            state.onClosed(reason)
        }
    }
}

/// A handle to one open relay channel. All I/O goes through the hub actor;
/// the handle just carries the id.
public final class CloudRelayChannel: Sendable {
    public let id: String
    private let hub: CloudHubConnection

    init(id: String, hub: CloudHubConnection) {
        self.id = id
        self.hub = hub
    }

    /// Seals and sends one JSON payload on the channel.
    public func sendJSON(_ value: some Encodable & Sendable) async throws {
        try await hub.send(channelId: id, plaintext: JSONEncoder().encode(value))
    }

    /// Seals and sends raw plaintext bytes on the channel.
    public func send(plaintext: Data) async throws {
        try await hub.send(channelId: id, plaintext: plaintext)
    }

    /// Closes the channel toward the peer. The channel's `onClosed` callback
    /// does not fire for self-initiated closes.
    public func close(reason: CloudChannelCloseReason) async {
        await hub.closeChannel(id, reason: reason)
    }
}
