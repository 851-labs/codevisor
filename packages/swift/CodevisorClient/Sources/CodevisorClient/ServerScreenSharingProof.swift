import CryptoKit
import Foundation

public struct ServerScreenSharingProof: Codable, Sendable, Equatable {
  public static let purpose = "codevisor.screen-sharing.start.v1"

  public let nonce: String
  public let signature: String

  public init(nonce: String, signature: String) {
    self.nonce = nonce
    self.signature = signature
  }

  public init(
    of request: ServerScreenSharingRequest, answering challenge: ServerScreenSharingChallenge,
    signer: ScreenSharingStartSigner
  ) throws {
    guard let message = Self.message(for: request, hostKey: challenge.hostKey, nonce: challenge.nonce) else {
      throw CocoaError(.coderInvalidValue)
    }

    self.init(nonce: challenge.nonce, signature: try signer.sign(message).hexEncoded)
  }

  public static func message(for request: ServerScreenSharingRequest, hostKey: String, nonce: String) -> Data? {
    guard let app = request.app, let intent = request.intent else { return nil }

    let lines = [
      purpose, request.operation.rawValue, hostKey.lowercased(), nonce.lowercased(), app.key.lowercased(),
      request.viewerId.uuidString.lowercased(), intent.rawValue, request.displayId ?? "",
    ]
    return Data(lines.joined(separator: "\n").utf8)
  }

  public func proves(_ request: ServerScreenSharingRequest, to hostKey: String) -> Bool {
    guard let app = request.app, let message = Self.message(for: request, hostKey: hostKey, nonce: nonce),
      let key = Data(hexEncoded: app.key).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
      let signature = Data(hexEncoded: signature)
    else { return false }

    return key.isValidSignature(signature, for: message)
  }
}

extension Data {
  public init?(hexEncoded text: String) {
    let digits = Array(text.utf8)
    guard digits.count.isMultiple(of: 2) else { return nil }

    var bytes: [UInt8] = []
    for index in stride(from: 0, to: digits.count, by: 2) {
      guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else { return nil }

      bytes.append(byte)
    }
    self.init(bytes)
  }

  public var hexEncoded: String { map { String(format: "%02x", $0) }.joined() }
}
