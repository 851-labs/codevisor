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
