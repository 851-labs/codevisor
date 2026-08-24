import Foundation
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

// MARK: - Fake WebSocket seam

/// A scripted WebSocket connection: the test (or a scripted machine) feeds
/// inbound messages through `push`/`finish`, and every outbound send is both
/// recorded and forwarded to `onSend`.
final class FakeWebSocketConnection: ServerWebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let inbound: AsyncThrowingStream<ServerWebSocketMessage, any Error>
    private let inboundContinuation: AsyncThrowingStream<ServerWebSocketMessage, any Error>.Continuation
    private var iterator: AsyncThrowingStream<ServerWebSocketMessage, any Error>.Iterator
    private var sentMessages: [ServerWebSocketMessage] = []
    var onSend: (@Sendable (ServerWebSocketMessage) -> Void)?
    var closeCodeOnDisconnect: URLSessionWebSocketTask.CloseCode = .invalid
    var failsSends = false

    init() {
        (inbound, inboundContinuation) =
            AsyncThrowingStream<ServerWebSocketMessage, any Error>.makeStream()
        iterator = inbound.makeAsyncIterator()
    }

    var sent: [ServerWebSocketMessage] {
        lock.withLock { sentMessages }
    }

    var sentTexts: [String] {
        sent.compactMap {
            if case let .string(text) = $0 { text } else { nil }
        }
    }

    func push(_ message: ServerWebSocketMessage) {
        inboundContinuation.yield(message)
    }

    func pushJSON(_ json: String) {
        inboundContinuation.yield(.string(json))
    }

    /// Ends the connection: the client's pending/next receive throws.
    func disconnect() {
        inboundContinuation.finish(throwing: URLError(.networkConnectionLost))
    }

    func send(_ message: ServerWebSocketMessage) async throws {
        if failsSends { throw URLError(.networkConnectionLost) }
        lock.withLock { sentMessages.append(message) }
        onSend?(message)
    }

    func receive() async throws -> ServerWebSocketMessage {
        guard let message = try await iterator.next() else {
            throw URLError(.networkConnectionLost)
        }
        return message
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        inboundContinuation.finish(throwing: URLError(.cancelled))
    }

    var closeCode: URLSessionWebSocketTask.CloseCode {
        closeCodeOnDisconnect
    }
}

/// Hands out connections built by `makeConnection` — one per connect call.
final class FakeWebSocketTransport: ServerWebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let makeConnection: @Sendable (URLRequest) -> any ServerWebSocketConnecting
    private var requestedURLs: [URL] = []

    init(makeConnection: @escaping @Sendable (URLRequest) -> any ServerWebSocketConnecting) {
        self.makeConnection = makeConnection
    }

    var requests: [URL] {
        lock.withLock { requestedURLs }
    }

    func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
        if let url = request.url {
            lock.withLock { requestedURLs.append(url) }
        }
        return makeConnection(request)
    }
}

// MARK: - Scripted hub + machine

/// A fake hub (and optionally a scripted responder machine behind it) living
/// on the other end of a FakeWebSocketConnection: answers `hello` with
/// `welcome` and hands relay envelopes to `onRelay`.
final class ScriptedCloudHub: @unchecked Sendable {
    struct RelayEnvelope {
        var machineId: String
        var frame: CloudRelayFrame
        var payload: Data
    }

    private struct RelayHeader: Codable {
        var machineId: String
        var frame: CloudRelayFrame
    }

    private let lock = NSLock()
    let socket = FakeWebSocketConnection()
    let machines: [CloudMachine]
    private var relayed: [RelayEnvelope] = []
    /// Called (synchronously, in send order) for every relay envelope the app
    /// sends. Push responses through `relayToApp`.
    var onRelay: (@Sendable (RelayEnvelope) -> Void)?
    private(set) var sawHello = false
    var appPublicKey: String?
    var respondsToPing = true

    init(machines: [CloudMachine] = []) {
        self.machines = machines
        socket.onSend = { [weak self] message in
            self?.handle(message)
        }
    }

    var relayEnvelopes: [RelayEnvelope] {
        lock.withLock { relayed }
    }

    func relayToApp(machineId: String, frame: CloudRelayFrame, payload: Data = Data()) {
        let header = try! JSONEncoder().encode(RelayHeader(machineId: machineId, frame: frame))
        socket.push(
            .data(CloudRelayWire.encode([CloudRelayEnvelope(header: header, payload: payload)]))
        )
    }

    func relayToApp(machineId: String, sealed: (frame: CloudRelayFrame, payload: Data)) {
        relayToApp(machineId: machineId, frame: sealed.frame, payload: sealed.payload)
    }

    func presenceToApp(_ machine: CloudMachine) {
        struct Envelope: Encodable {
            var t = "presence"
            var machine: CloudMachine
        }
        let data = try! JSONEncoder().encode(Envelope(machine: machine))
        socket.push(.string(String(decoding: data, as: UTF8.self)))
    }

    func machineResetToApp(machineId: String) {
        struct Envelope: Encodable {
            var t = "machine-reset"
            var machineId: String
        }
        let data = try! JSONEncoder().encode(Envelope(machineId: machineId))
        socket.push(.string(String(decoding: data, as: UTF8.self)))
    }

    func errorToApp(
        code: String,
        message: String,
        machineId: String? = nil,
        channelId: String? = nil
    ) {
        struct Envelope: Encodable {
            var t = "error"
            var code: String
            var message: String
            var machineId: String?
            var channelId: String?
        }
        let data = try! JSONEncoder().encode(
            Envelope(
                code: code,
                message: message,
                machineId: machineId,
                channelId: channelId
            ))
        socket.push(.string(String(decoding: data, as: UTF8.self)))
    }

    private func handle(_ message: ServerWebSocketMessage) {
        if case let .data(binary) = message {
            guard let envelopes = try? CloudRelayWire.decode(binary) else { return }
            for wire in envelopes {
                guard let header = try? JSONDecoder().decode(RelayHeader.self, from: wire.header)
                else { continue }
                let envelope = RelayEnvelope(
                    machineId: header.machineId,
                    frame: header.frame,
                    payload: wire.payload
                )
                lock.withLock { relayed.append(envelope) }
                onRelay?(envelope)
            }
            return
        }
        guard case let .string(text) = message else { return }
        let data = Data(text.utf8)
        struct Probe: Decodable {
            var t: String
        }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return }
        switch probe.t {
        case "hello":
            struct Hello: Decodable {
                struct Device: Decodable {
                    var deviceId: String
                    var kind: String
                    var publicKey: String
                }

                var device: Device
            }
            if let hello = try? JSONDecoder().decode(Hello.self, from: data) {
                lock.withLock {
                    sawHello = true
                    appPublicKey = hello.device.publicKey
                }
            }
            let welcome = try! JSONEncoder().encode(WelcomePayload(machines: machines))
            socket.push(.string(String(decoding: welcome, as: UTF8.self)))
        case "ping":
            if respondsToPing {
                socket.pushJSON(#"{"t":"pong"}"#)
            }
        default:
            break
        }
    }

    private struct WelcomePayload: Encodable {
        var t = "welcome"
        var `protocol` = 2
        var connectionId = "conn-1"
        var machines: [CloudMachine]
    }
}

/// The responder half of relay channels for tests: performs the machine-side
/// key agreement, tracks per-channel seqs both ways, and lets a script send
/// sealed frames back.
final class ScriptedRelayMachine: @unchecked Sendable {
    let deviceId: String
    let secretKey: Data
    let publicKey: String
    private let lock = NSLock()
    private var channels: [String: Channel] = [:]

    final class Channel {
        let cipher: CloudChannelCipher
        var nextInboundSeq: UInt64 = 0
        var nextOutboundSeq: UInt64 = 0
        var openPayload: Data?
        var messages: [Data] = []
        var closeReason: CloudChannelCloseReason?

        init(cipher: CloudChannelCipher) {
            self.cipher = cipher
        }
    }

    init(deviceId: String = "machine-1") {
        self.deviceId = deviceId
        let pair = CloudChannelCrypto.generateKeyPair()
        secretKey = pair.secretKey
        publicKey = pair.publicKey
    }

    var presence: CloudMachine {
        CloudMachine(
            deviceId: deviceId,
            name: "Scripted Machine",
            os: "macOS",
            publicKey: publicKey,
            online: true,
            lastSeenAt: "2026-01-01T00:00:00.000Z"
        )
    }

    func channel(_ id: String) -> Channel? {
        lock.withLock { channels[id] }
    }

    /// Handles one app→machine relay envelope, decrypting with the machine's
    /// keys. Returns the decrypted payload for open/data frames.
    @discardableResult
    func receive(
        _ frame: CloudRelayFrame,
        payload: Data,
        appPublicKey: String
    ) throws -> Data? {
        switch frame {
        case let .open(channelId, seq, ephemeralKey):
            let cipher = try CloudChannelCrypto.acceptChannel(
                responderSecretKey: secretKey,
                openerPublicKey: appPublicKey,
                ephemeralPublicKey: ephemeralKey
            )
            let channel = Channel(cipher: cipher)
            channel.nextInboundSeq = seq + 1
            channel.openPayload = try cipher.open(
                payload, channelId: channelId, direction: .openerToResponder, seq: seq
            )
            lock.withLock { channels[channelId] = channel }
            return channel.openPayload
        case let .data(channelId, seq):
            guard let channel = channel(channelId), channel.nextInboundSeq == seq else {
                throw CloudChannelCryptoError.openFailed
            }
            channel.nextInboundSeq += 1
            let plaintext = try channel.cipher.open(
                payload, channelId: channelId, direction: .openerToResponder, seq: seq
            )
            channel.messages.append(plaintext)
            return plaintext
        case let .credit(channelId, seq, _):
            guard let channel = channel(channelId), channel.nextInboundSeq == seq else {
                throw CloudChannelCryptoError.openFailed
            }
            channel.nextInboundSeq += 1
            return nil
        case let .close(channelId, seq, reason):
            guard let channel = channel(channelId), channel.nextInboundSeq == seq else {
                throw CloudChannelCryptoError.openFailed
            }
            channel.nextInboundSeq += 1
            channel.closeReason = reason
            return nil
        }
    }

    /// Seals a machine→app data frame (header + ciphertext payload).
    func sealData(
        channelId: String,
        payload: Data
    ) throws -> (frame: CloudRelayFrame, payload: Data) {
        guard let channel = channel(channelId) else { throw CloudChannelCryptoError.openFailed }
        let seq = channel.nextOutboundSeq
        channel.nextOutboundSeq += 1
        let box = try channel.cipher.seal(
            payload, channelId: channelId, direction: .responderToOpener, seq: seq
        )
        return (frame: .data(channelId: channelId, seq: seq), payload: box)
    }

    func creditFrame(channelId: String, bytes: Int) -> CloudRelayFrame {
        guard let channel = channel(channelId) else {
            return .credit(channelId: channelId, seq: 0, bytes: bytes)
        }
        let seq = channel.nextOutboundSeq
        channel.nextOutboundSeq += 1
        return .credit(channelId: channelId, seq: seq, bytes: bytes)
    }

    func closeFrame(channelId: String, reason: CloudChannelCloseReason) -> CloudRelayFrame {
        guard let channel = channel(channelId) else {
            return .close(channelId: channelId, seq: 0, reason: reason)
        }
        let seq = channel.nextOutboundSeq
        channel.nextOutboundSeq += 1
        return .close(channelId: channelId, seq: seq, reason: reason)
    }
}

// MARK: - Polling helper

/// Waits until `condition` is true (checking every few milliseconds) or the
/// timeout elapses — for asserting on work that crosses actor boundaries.
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
