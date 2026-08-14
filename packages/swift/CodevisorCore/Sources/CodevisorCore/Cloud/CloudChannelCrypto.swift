import CryptoKit
import Foundation

/// End-to-end encryption for cloud relay channels — the CryptoKit twin of
/// packages/cloud-crypto (which uses @noble); the two must stay byte-for-byte
/// compatible.
///
/// Key agreement per channel (Noise-IK-flavoured, deliberately minimal):
///   dh1 = X25519(ephemeral, responderStatic)    — forward secrecy
///   dh2 = X25519(openerStatic, responderStatic) — mutual authentication
///   key = HKDF-SHA256(ikm = dh1 || dh2, salt = ephemeralPub, info = INFO)
///
/// Frames are IETF ChaCha20-Poly1305 boxes. Nonces are deterministic —
/// 12 bytes = [direction byte, 0, 0, 0, seq as u64 BE] — and never travel on
/// the wire; they never repeat under one key because every channel open
/// derives a fresh key and each direction's seq is strictly monotonic. The
/// AAD additionally binds (channelId, direction, seq) so ciphertext cannot be
/// replayed across channels, directions, or positions.
public enum CloudChannelCrypto {
    static let info = Data("codevisor-cloud-channel-v1".utf8)
    public static let keyLength = 32
    public static let nonceLength = 12

    /// Generates a device's long-lived static X25519 keypair (raw secret +
    /// base64url public), or a per-channel ephemeral.
    public static func generateKeyPair() -> (secretKey: Data, publicKey: String) {
        let secret = Curve25519.KeyAgreement.PrivateKey()
        return (
            secretKey: secret.rawRepresentation,
            publicKey: base64URLEncode(secret.publicKey.rawRepresentation)
        )
    }

    /// Derives the base64url public key for a raw X25519 secret key.
    public static func publicKey(forSecretKey secretKey: Data) throws -> String {
        let key = try privateKey(secretKey)
        return base64URLEncode(key.publicKey.rawRepresentation)
    }

    /// Opener side (the app connecting to a machine): fresh ephemeral per
    /// channel open.
    public static func openChannel(
        openerSecretKey: Data,
        responderPublicKey: String
    ) throws -> (ephemeralPublicKey: String, cipher: CloudChannelCipher) {
        try openChannel(
            openerSecretKey: openerSecretKey,
            responderPublicKey: responderPublicKey,
            ephemeralSecretKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        )
    }

    /// Deterministic-ephemeral variant for cross-implementation test vectors.
    static func openChannel(
        openerSecretKey: Data,
        responderPublicKey: String,
        ephemeralSecretKey: Data
    ) throws -> (ephemeralPublicKey: String, cipher: CloudChannelCipher) {
        let ephemeral = try privateKey(ephemeralSecretKey)
        let opener = try privateKey(openerSecretKey)
        let responder = try publicKey(responderPublicKey)
        let dh1 = try ephemeral.sharedSecretFromKeyAgreement(with: responder)
        let dh2 = try opener.sharedSecretFromKeyAgreement(with: responder)
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        return (
            ephemeralPublicKey: base64URLEncode(ephemeralPublic),
            cipher: deriveCipher(dh1: dh1, dh2: dh2, ephemeralPublic: ephemeralPublic)
        )
    }

    /// Responder side (a machine accepting a channel; the app never responds,
    /// but the derivation is needed to verify vectors against the TS peer).
    public static func acceptChannel(
        responderSecretKey: Data,
        openerPublicKey: String,
        ephemeralPublicKey: String
    ) throws -> CloudChannelCipher {
        let responder = try privateKey(responderSecretKey)
        let opener = try publicKey(openerPublicKey)
        guard let ephemeralPublicData = base64URLDecode(ephemeralPublicKey) else {
            throw CloudChannelCryptoError.invalidBase64URL
        }
        let ephemeral = try publicKey(ephemeralPublicKey)
        let dh1 = try responder.sharedSecretFromKeyAgreement(with: ephemeral)
        let dh2 = try responder.sharedSecretFromKeyAgreement(with: opener)
        return deriveCipher(dh1: dh1, dh2: dh2, ephemeralPublic: ephemeralPublicData)
    }

    private static func deriveCipher(
        dh1: SharedSecret,
        dh2: SharedSecret,
        ephemeralPublic: Data
    ) -> CloudChannelCipher {
        var ikm = Data()
        dh1.withUnsafeBytes { ikm.append(contentsOf: $0) }
        dh2.withUnsafeBytes { ikm.append(contentsOf: $0) }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: ephemeralPublic,
            info: info,
            outputByteCount: keyLength
        )
        return CloudChannelCipher(key: key)
    }

    private static func privateKey(_ raw: Data) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard raw.count == keyLength,
            let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        else { throw CloudChannelCryptoError.invalidKey }
        return key
    }

    private static func publicKey(_ base64URL: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let raw = base64URLDecode(base64URL) else {
            throw CloudChannelCryptoError.invalidBase64URL
        }
        guard raw.count == keyLength,
            let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        else { throw CloudChannelCryptoError.invalidKey }
        return key
    }

    // MARK: - base64url (unpadded)

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecode(_ encoded: String) -> Data? {
        guard
            encoded.allSatisfy({ character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
            })
        else { return nil }
        var base64 =
            encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

public enum CloudChannelCryptoError: Error, Equatable, Sendable {
    case invalidKey
    case invalidBase64URL
    case invalidBox
    case sealFailed
    case openFailed
}

/// Direction of a frame relative to the channel opener. The app is always the
/// opener of relay channels.
public enum CloudChannelDirection: String, Sendable {
    case openerToResponder = "opener-to-responder"
    case responderToOpener = "responder-to-opener"

    var nonceByte: UInt8 {
        switch self {
        case .openerToResponder: 1
        case .responderToOpener: 2
        }
    }
}

/// Symmetric cipher for one channel. Both peers converge on the same key and
/// use the direction tag to keep their AAD (and nonce) spaces disjoint.
public struct CloudChannelCipher: Sendable {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    public init(keyData: Data) throws {
        guard keyData.count == CloudChannelCrypto.keyLength else {
            throw CloudChannelCryptoError.invalidKey
        }
        self.key = SymmetricKey(data: keyData)
    }

    /// Seals a plaintext into a base64url `box` (ciphertext ‖ tag — the
    /// deterministic nonce is never included).
    public func seal(
        _ plaintext: Data,
        channelId: String,
        direction: CloudChannelDirection,
        seq: UInt64
    ) throws -> String {
        let nonce = try ChaChaPoly.Nonce(data: Self.nonce(direction: direction, seq: seq))
        guard
            let sealed = try? ChaChaPoly.seal(
                plaintext,
                using: key,
                nonce: nonce,
                authenticating: Self.aad(channelId: channelId, direction: direction, seq: seq)
            )
        else { throw CloudChannelCryptoError.sealFailed }
        return CloudChannelCrypto.base64URLEncode(sealed.ciphertext + sealed.tag)
    }

    /// Opens a base64url `box`, authenticating (channelId, direction, seq).
    public func open(
        _ box: String,
        channelId: String,
        direction: CloudChannelDirection,
        seq: UInt64
    ) throws -> Data {
        guard let combined = CloudChannelCrypto.base64URLDecode(box), combined.count >= 16 else {
            throw CloudChannelCryptoError.invalidBox
        }
        let nonce = try ChaChaPoly.Nonce(data: Self.nonce(direction: direction, seq: seq))
        let sealed = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: combined.dropLast(16),
            tag: combined.suffix(16)
        )
        guard
            let plaintext = try? ChaChaPoly.open(
                sealed,
                using: key,
                authenticating: Self.aad(channelId: channelId, direction: direction, seq: seq)
            )
        else { throw CloudChannelCryptoError.openFailed }
        return plaintext
    }

    static func nonce(direction: CloudChannelDirection, seq: UInt64) -> Data {
        var nonce = Data(count: CloudChannelCrypto.nonceLength)
        nonce[0] = direction.nonceByte
        withUnsafeBytes(of: seq.bigEndian) { nonce.replaceSubrange(4..<12, with: $0) }
        return nonce
    }

    static func aad(channelId: String, direction: CloudChannelDirection, seq: UInt64) -> Data {
        Data("\(channelId)|\(direction.rawValue)|\(seq)".utf8)
    }
}
