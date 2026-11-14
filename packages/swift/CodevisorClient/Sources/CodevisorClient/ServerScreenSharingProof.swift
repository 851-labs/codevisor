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
    let target = request.displayId ?? ""
    guard let app = request.app, let intent = request.intent, [.start, .restart].contains(request.operation),
      [hostKey, nonce, app.key].allSatisfy(isKey),
      !target.unicodeScalars.contains(where: CharacterSet.newlines.contains)
    else { return nil }

    let lines = [
      purpose, request.operation.rawValue, hostKey, nonce, app.key, request.viewerId.uuidString.lowercased(),
      intent.rawValue, target,
    ]
    return Data(lines.joined(separator: "\n").utf8)
  }

  public static func isKey(_ text: String) -> Bool {
    text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
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
      guard let high = Self.hexValue(digits[index]), let low = Self.hexValue(digits[index + 1]) else { return nil }

      bytes.append(high << 4 | low)
    }
    self.init(bytes)
  }

  private static func hexValue(_ digit: UInt8) -> UInt8? {
    switch digit {
    case 48...57: digit - 48
    case 65...70: digit - 55
    case 97...102: digit - 87
    default: nil
    }
  }

  public var hexEncoded: String { map { String(format: "%02x", $0) }.joined() }
}
