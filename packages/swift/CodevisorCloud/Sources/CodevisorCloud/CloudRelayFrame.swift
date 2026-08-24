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

/// One relay frame's header metadata. The ciphertext never appears here — it
/// rides beside the header as the envelope payload (open/data frames), and
/// credit/close frames carry an empty payload.
public enum CloudRelayFrame: Sendable, Equatable {
    case open(channelId: String, seq: UInt64, ephemeralKey: String)
    case data(channelId: String, seq: UInt64)
    case credit(channelId: String, seq: UInt64, bytes: Int)
    case close(channelId: String, seq: UInt64, reason: CloudChannelCloseReason)

    public var channelId: String {
        switch self {
        case let .open(channelId, _, _), let .data(channelId, _),
            let .credit(channelId, _, _), let .close(channelId, _, _):
            channelId
        }
    }

    public var seq: UInt64 {
        switch self {
        case let .open(_, seq, _), let .data(_, seq),
            let .credit(_, seq, _), let .close(_, seq, _):
            seq
        }
    }
}

extension CloudRelayFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case t, channelId, seq, ephemeralKey, bytes, reason
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
                ephemeralKey: try container.decode(String.self, forKey: .ephemeralKey)
            )
        case "data":
            self = .data(channelId: channelId, seq: seq)
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
        case let .open(_, _, ephemeralKey):
            try container.encode("open", forKey: .t)
            try container.encode(ephemeralKey, forKey: .ephemeralKey)
        case .data:
            try container.encode("data", forKey: .t)
        case let .credit(_, _, bytes):
            try container.encode("credit", forKey: .t)
            try container.encode(bytes, forKey: .bytes)
        case let .close(_, _, reason):
            try container.encode("close", forKey: .t)
            try container.encode(reason, forKey: .reason)
        }
    }
}

// MARK: - Binary relay envelopes

/// One decoded relay envelope: the raw JSON header bytes plus the payload.
public struct CloudRelayEnvelope: Sendable {
    public var header: Data
    public var payload: Data

    public init(header: Data, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

/// The relay's binary framing, the Swift twin of @codevisor/api
/// encodeRelayEnvelopes: a binary WebSocket message is one or more envelopes,
/// each `u32 BE header length | header JSON | u32 BE payload length | payload`.
/// Senders may coalesce several envelopes into one message; receivers process
/// them in order.
public enum CloudRelayWire {
    public static func encode(_ envelopes: [CloudRelayEnvelope]) -> Data {
        var message = Data()
        for envelope in envelopes {
            withUnsafeBytes(of: UInt32(envelope.header.count).bigEndian) {
                message.append(contentsOf: $0)
            }
            message.append(envelope.header)
            withUnsafeBytes(of: UInt32(envelope.payload.count).bigEndian) {
                message.append(contentsOf: $0)
            }
            message.append(envelope.payload)
        }
        return message
    }

    public static func decode(_ message: Data) throws -> [CloudRelayEnvelope] {
        var envelopes: [CloudRelayEnvelope] = []
        var offset = message.startIndex
        func readLength() throws -> Int {
            guard message.distance(from: offset, to: message.endIndex) >= 4 else {
                throw CloudRelayWireError.truncated
            }
            let end = message.index(offset, offsetBy: 4)
            var length: UInt32 = 0
            for byte in message[offset..<end] {
                length = length << 8 | UInt32(byte)
            }
            offset = end
            return Int(length)
        }
        func readBytes(_ count: Int) throws -> Data {
            guard message.distance(from: offset, to: message.endIndex) >= count else {
                throw CloudRelayWireError.truncated
            }
            let end = message.index(offset, offsetBy: count)
            defer { offset = end }
            return Data(message[offset..<end])
        }
        while offset < message.endIndex {
            let header = try readBytes(try readLength())
            let payload = try readBytes(try readLength())
            envelopes.append(CloudRelayEnvelope(header: header, payload: payload))
        }
        guard !envelopes.isEmpty else { throw CloudRelayWireError.empty }
        return envelopes
    }
}

public enum CloudRelayWireError: Error, Equatable, Sendable {
    case truncated
    case empty
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
