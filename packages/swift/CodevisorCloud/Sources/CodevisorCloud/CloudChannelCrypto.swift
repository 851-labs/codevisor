import CodevisorClient
import CryptoKit
import Foundation

public enum CloudChannelCrypto {
  static let info = Data("codevisor-cloud-channel-v1".utf8)
  public static let keyLength = 32
  public static let nonceLength = 12

  public static func generateKeyPair() -> (secretKey: Data, publicKey: String) {
    let secret = Curve25519.KeyAgreement.PrivateKey()
    return (
      secretKey: secret.rawRepresentation,
      publicKey: base64URLEncode(secret.publicKey.rawRepresentation)
    )
  }

  public static func publicKey(forSecretKey secretKey: Data) throws -> String {
    let key = try privateKey(secretKey)
    return base64URLEncode(key.publicKey.rawRepresentation)
  }

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

  public func seal(
    _ plaintext: Data,
    channelId: String,
    direction: CloudChannelDirection,
    seq: UInt64
  ) throws -> Data {
    let nonce = try ChaChaPoly.Nonce(data: Self.nonce(direction: direction, seq: seq))
    guard
      let sealed = try? ChaChaPoly.seal(
        plaintext,
        using: key,
        nonce: nonce,
        authenticating: Self.aad(channelId: channelId, direction: direction, seq: seq)
      )
    else { throw CloudChannelCryptoError.sealFailed }
    return sealed.ciphertext + sealed.tag
  }

  public func open(
    _ box: Data,
    channelId: String,
    direction: CloudChannelDirection,
    seq: UInt64
  ) throws -> Data {
    guard box.count >= 16 else {
      throw CloudChannelCryptoError.invalidBox
    }
    let nonce = try ChaChaPoly.Nonce(data: Self.nonce(direction: direction, seq: seq))
    let sealed = try ChaChaPoly.SealedBox(
      nonce: nonce,
      ciphertext: box.dropLast(16),
      tag: box.suffix(16)
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
