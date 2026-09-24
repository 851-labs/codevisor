import Foundation
import ScreenSharingTesting
import Testing
@testable import ScreenSharing

/// Apple's account sign-in, RFB security type 30 (851-2341).
struct RFBAppleAuthenticationTests {
  // MARK: L1: the arithmetic

  /// a^e mod m with 64-bit integers, the obvious way.
  static func naivePower(_ base: UInt64, _ exponent: UInt64, _ modulus: UInt64) -> UInt64 {
    func multiply(_ a: UInt64, _ b: UInt64) -> UInt64 {
      let (high, low) = a.multipliedFullWidth(by: b)
      return modulus.dividingFullWidth((high, low)).remainder
    }
    var result: UInt64 = 1 % modulus, base = base % modulus, exponent = exponent
    while exponent > 0 {
      if exponent & 1 == 1 { result = multiply(result, base) }
      base = multiply(base, base)
      exponent >>= 1
    }
    return result
  }

  static func big(_ value: UInt64) -> RFBBigUInt {
    RFBBigUInt(bytes: (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) })
  }

  @Test func modularPowerMatchesTheObviousArithmetic() {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<300 {
      // One- and two-limb odd moduli, bases below them, exponents of any size.
      let modulus =
        (Bool.random(using: &generator) ? UInt64.random(in: 3...UInt64(UInt32.max)) : UInt64.random(in: 3...UInt64.max))
        | 1
      let base = UInt64.random(in: 0..<modulus)
      let exponent = UInt64.random(in: 0...UInt64.max)
      let expected = Self.naivePower(base, exponent, modulus)
      #expect(Self.big(base).power(Self.big(exponent), modulo: Self.big(modulus)) == Self.big(expected))
    }
  }

  @Test func diffieHellmanAgreesWithTheRealGroup() {
    let prime = RFBLoopbackServer.appleAuthenticationPrime
    #expect(prime.count == 128 && prime.last! & 1 == 1)
    let modulus = RFBBigUInt(bytes: prime)
    let a = RFBBigUInt(bytes: (0..<128).map { _ in UInt8.random(in: 0...255) })
    let b = RFBBigUInt(bytes: (0..<128).map { _ in UInt8.random(in: 0...255) })
    let g = RFBBigUInt(2)
    let shared = g.power(a, modulo: modulus).power(b, modulo: modulus)
    #expect(shared == g.power(b, modulo: modulus).power(a, modulo: modulus))
    #expect(g.power(RFBBigUInt(1), modulo: modulus) == g)
    #expect(g.power(RFBBigUInt(0), modulo: modulus) == RFBBigUInt(1))
    #expect(RFBBigUInt(bytes: shared.bytes(count: 128)) == shared)
  }

  /// Fermat: g^(p-1) = 1 and g^p = g for the real 1024-bit prime, through every limb of the multiply.
  @Test func fermatHoldsForTheRealPrime() {
    let prime = RFBLoopbackServer.appleAuthenticationPrime
    let modulus = RFBBigUInt(bytes: prime)
    var lessOne = prime
    lessOne[lessOne.count - 1] -= 1  // odd, so no borrow
    for g in [2, 3, 65537] as [UInt64] {
      #expect(RFBBigUInt(g).power(RFBBigUInt(bytes: lessOne), modulo: modulus) == RFBBigUInt(1))
      #expect(RFBBigUInt(g).power(modulus, modulo: modulus) == RFBBigUInt(g))
    }
  }

  /// Macs offer a 4096-bit group (tuftlord, 851-2341). The secret exponent is
  /// 512 bits, not the group's size: a full-size one made sign-in take 86 s in
  /// the (debug) rig.
  @Test func aMacsFourThousandBitGroupUsesAFiveHundredBitExponent() throws {
    #expect(RFBAppleAuthentication.privateKeyLength(forKeyLength: 512) == 64)
    #expect(RFBAppleAuthentication.privateKeyLength(forKeyLength: 128) == 64)
    #expect(RFBAppleAuthentication.privateKeyLength(forKeyLength: 16) == 16)
    // A 4096-bit group's reply: 128 bytes of credentials, then a 512-byte key.
    // (A short test exponent keeps this fast; agreement is checked on the real prime above.)
    var prime = [UInt8](repeating: 0x5B, count: 512)
    prime[0] = 0xC3
    prime[511] = 0x7F
    let modulus = RFBBigUInt(bytes: prime)
    let secret: [UInt8] = [0x01, 0x23, 0x45, 0x67]
    let response = try RFBAppleAuthentication.response(
      generator: 2, prime: prime, serverKey: [UInt8](repeating: 0x11, count: 512), username: "alex", password: "pw",
      privateKey: secret)
    #expect(response.count == 128 + 512)
    let clientKey = RFBBigUInt(bytes: Array(response.suffix(512)))
    #expect(clientKey == RFBBigUInt(2).power(RFBBigUInt(bytes: secret), modulo: modulus))
  }

  @Test func aesIsTheStandardCipher() throws {
    // FIPS-197 appendix C.1.
    let key = (0..<16).map { UInt8($0) }
    let plain: [UInt8] = [
      0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    ]
    let cipher = try RFBAppleAuthentication.aes128ECB(encrypt: true, key: key, data: plain)
    #expect(cipher == [0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a])
    #expect(try RFBAppleAuthentication.aes128ECB(encrypt: false, key: key, data: cipher) == plain)
    #expect(throws: RFBError.self) { try RFBAppleAuthentication.aes128ECB(encrypt: true, key: key, data: [1, 2]) }
  }

  @Test func credentialsAreNulTerminatedAndPadded() throws {
    let block = try RFBAppleAuthentication.block("alex", padding: { 0xAB })
    #expect(block.count == 64 && Array(block.prefix(5)) == Array("alex".utf8) + [0] && block.last == 0xAB)
    #expect(RFBAppleAuthentication.text(ofBlock: block[...]) == "alex")
    #expect(throws: RFBError.self) {
      try RFBAppleAuthentication.block(String(repeating: "x", count: 64), padding: { 0 })
    }
  }

  @Test func badParametersAreErrorsNotTraps() {
    let prime = RFBLoopbackServer.appleAuthenticationPrime
    #expect(throws: RFBError.self) {
      try RFBAppleAuthentication.response(
        generator: 2, prime: [0xFF], serverKey: [1], username: "a", password: "b")
    }
    #expect(throws: RFBError.self) {
      // The server's key must be below the prime.
      try RFBAppleAuthentication.response(
        generator: 2, prime: prime, serverKey: [UInt8](repeating: 0xFF, count: 128), username: "a", password: "b")
    }
    #expect(throws: RFBError.self) {
      try RFBAppleAuthentication.response(
        generator: 1, prime: prime, serverKey: [UInt8](repeating: 1, count: 128), username: "a", password: "b")
    }
  }

  // MARK: L2: against the reference server

  func server(account: (String, String)?) async throws -> RFBLoopbackServer {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.securityTypes = [
      RFBSecurityType.appleRemoteDesktop.rawValue, RFBSecurityType.vncAuthentication.rawValue,
    ]
    configuration.account = account.map { (username: $0.0, password: $0.1) }
    configuration.password = "vnc-pass"
    return try await RFBLoopbackServer(configuration: configuration)
  }

  @Test func signsInWithAMacOSAccount() async throws {
    let server = try await server(account: ("alex", "correct horse"))
    defer { server.stop() }
    let (client, outcome) = try await VNCConnection.open(
      host: "127.0.0.1", port: server.port, password: "correct horse", username: "alex")
    defer { client.close() }
    #expect(outcome.security == .appleRemoteDesktop)
    #expect(outcome.parameters.width > 0)
  }

  @Test func aWrongAccountFailsWithTheServersReason() async throws {
    let server = try await server(account: ("alex", "correct horse"))
    defer { server.stop() }
    await #expect(throws: RFBError.authenticationFailed("Authentication failed")) {
      _ = try await VNCConnection.open(host: "127.0.0.1", port: server.port, password: "wrong", username: "alex")
    }
  }

  @Test func withoutAUsernameTheVNCPasswordIsUsed() async throws {
    let server = try await server(account: ("alex", "correct horse"))
    defer { server.stop() }
    let (client, outcome) = try await VNCConnection.open(host: "127.0.0.1", port: server.port, password: "vnc-pass")
    defer { client.close() }
    #expect(outcome.security == .vncAuthentication)
  }

  /// 851-2342: the sign-in form asks for a user name only when the Mac offers account sign-in.
  @Test func theOfferedSecurityTypesAreReadWithoutSigningIn() async throws {
    let server = try await server(account: ("alex", "correct horse"))
    defer { server.stop() }
    #expect(
      try await VNCConnection.securityTypes(host: "127.0.0.1", port: server.port)
        == [RFBSecurityType.appleRemoteDesktop.rawValue, RFBSecurityType.vncAuthentication.rawValue])
  }
}
