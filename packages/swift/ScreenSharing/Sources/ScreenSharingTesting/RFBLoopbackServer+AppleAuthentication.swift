import CryptoKit
import Foundation
import ScreenSharing

/// Apple's account sign-in (RFB security type 30, 851-2341), the reference
/// server's side: a 1024-bit group, its public key, then the client's
/// encrypted credentials checked against `configuration.account`.
extension RFBLoopbackServer {
  /// RFC 2409's 1024-bit MODP group (group 2), for the reference server's Apple sign-in.
  public static let appleAuthenticationPrime: [UInt8] = {
    let hex =
      "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD"
      + "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
      + "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF"
    return stride(from: 0, to: hex.count, by: 2).map {
      let start = hex.index(hex.startIndex, offsetBy: $0)
      return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
  }()

  /// Runs the exchange; false (after sending the failure) when the account doesn't match.
  func authenticateAppleAccount(
    stream: RFBInputStream, transport: RFBNetworkTransport, version: RFBProtocolVersion
  ) async throws -> Bool {
    let prime = Self.appleAuthenticationPrime
    let secret = RFBBigUInt(bytes: (0..<prime.count).map { _ in UInt8.random(in: 0...255) })
    let modulus = RFBBigUInt(bytes: prime)
    var writer = RFBByteWriter()
    writer.u16(2)
    writer.u16(UInt16(prime.count))
    writer.append(prime)
    writer.append(RFBBigUInt(2).power(secret, modulo: modulus).bytes(count: prime.count))
    try await transport.write(writer.bytes)
    let encrypted = try await stream.bytes(128)
    let theirs = RFBBigUInt(bytes: try await stream.bytes(prime.count))
    let key = Array(Insecure.MD5.hash(data: theirs.power(secret, modulo: modulus).bytes(count: prime.count)))
    let credentials = try RFBAppleAuthentication.aes128ECB(encrypt: false, key: key, data: encrypted)
    let username = RFBAppleAuthentication.text(ofBlock: credentials[0..<64])
    let password = RFBAppleAuthentication.text(ofBlock: credentials[64..<128])
    guard let account = configuration.account, account.username == username, account.password == password else {
      let reason = Array("Authentication failed".utf8)
      try await transport.write([0, 0, 0, 1] + (version == .v3_8 ? [0, 0, 0, UInt8(reason.count)] + reason : []))
      return false
    }
    try await transport.write([0, 0, 0, 0])
    return true
  }
}
