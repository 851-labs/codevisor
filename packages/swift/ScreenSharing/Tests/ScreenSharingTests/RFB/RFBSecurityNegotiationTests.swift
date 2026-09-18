import Foundation
import Testing
@testable import ScreenSharing

/// Security negotiation (RFC 6143 §7.1.2) and the SecurityResult that follows:
/// which type the client picks from what the server offers, the single byte it
/// writes back, and the reason strings a refusal carries.
struct RFBSecurityNegotiationTests {
  private static let challenge = [UInt8](repeating: 0x5a, count: 16)

  /// `offered` is the 3.7/3.8 list; the reply the server needs after the pick
  /// differs, so each case names the type it expects the client to choose.
  private func negotiate(
    offered: [UInt8], password: String?, then tail: [UInt8] = u32(0) + RFBScript.serverInit()
  ) async throws -> (outcome: RFBHandshake.Outcome, written: [UInt8]) {
    let transport = ScriptedTransport(
      RFBScript.bytes("RFB 003.008\n") + [UInt8(offered.count)] + offered + tail, chunk: 5)
    return (try await performHandshake(transport, password: password), transport.written)
  }

  @Test func aListWithOnlyNoneIsAcceptedAndAcknowledgedWithOneByte() async throws {
    let (outcome, written) = try await negotiate(offered: [1], password: nil)
    #expect(outcome.security == .none)
    #expect(written == RFBProtocolVersion.v3_8.encoded + [1] + [1])  // chosen type, then ClientInit's shared flag
  }

  @Test func vncAuthenticationWinsOverNoneWhenAPasswordIsGiven() async throws {
    let (outcome, written) = try await negotiate(
      offered: [1, 2], password: "secret", then: Self.challenge + u32(0) + RFBScript.serverInit())
    #expect(outcome.security == .vncAuthentication)
    #expect(
      written == RFBProtocolVersion.v3_8.encoded + [2]
        + RFBVNCAuthentication.response(challenge: Self.challenge, password: "secret") + [1])
  }

  /// Order in the list carries no preference: the client picks by policy.
  @Test(arguments: [[UInt8]([2, 1]), [1, 2], [30, 1, 2], [1]])
  func noneWinsWhenNoPasswordIsGivenWhicheverOrderTheListIsIn(_ offered: [UInt8]) async throws {
    let (outcome, _) = try await negotiate(offered: offered, password: nil)
    #expect(outcome.security == .none)
  }

  @Test func onlyVNCAuthenticationWithoutAPasswordAsksForOne() async throws {
    await #expect(throws: RFBError.authenticationFailed("This VNC server requires a password.")) {
      try await negotiate(offered: [2], password: nil)
    }
  }

  @Test(arguments: [[UInt8]([16]), [18], [16, 18, 19], [30], [30, 35], [0]])
  func unsupportedOnlyListsAreReportedVerbatim(_ offered: [UInt8]) async throws {
    await #expect(throws: RFBError.securityUnsupported(offered)) {
      try await negotiate(offered: offered, password: "x")
    }
  }

  @Test func anEmptyListIsARefusalCarryingTheServersReason() async throws {
    let transport = ScriptedTransport(
      RFBScript.bytes("RFB 003.008\n") + [0] + u32(20) + RFBScript.bytes("Too many connections"), chunk: 5)
    await #expect(throws: RFBError.authenticationFailed("Too many connections")) {
      try await performHandshake(transport, password: nil)
    }
  }

  @Test func anEmptyRefusalReasonFallsBackToAGenericMessage() async throws {
    let transport = ScriptedTransport(RFBScript.bytes("RFB 003.008\n") + [0] + u32(0), chunk: 4)
    await #expect(throws: RFBError.authenticationFailed("The VNC server refused the connection.")) {
      try await performHandshake(transport, password: nil)
    }
  }

  /// The reason is bounded, so a hostile length never drives an unbounded read.
  @Test func anOversizedRefusalReasonIsMalformed() async throws {
    let transport = ScriptedTransport(RFBScript.bytes("RFB 003.008\n") + [0] + u32(4097), chunk: 4)
    await #expect(throws: RFBError.malformed("reason of 4097 bytes")) {
      try await performHandshake(transport, password: nil)
    }
    let atTheLimit = ScriptedTransport(
      RFBScript.bytes("RFB 003.008\n") + [0] + u32(4096) + [UInt8](repeating: UInt8(ascii: "x"), count: 4096),
      chunk: 512)
    await #expect(throws: RFBError.authenticationFailed(String(repeating: "x", count: 4096))) {
      try await performHandshake(atTheLimit, password: nil)
    }
  }

  // MARK: 3.3, where the server decides alone

  @Test func on33TheServerNamesTheTypeAndTheClientWritesNothingBack() async throws {
    let transport = ScriptedTransport(
      RFBScript.bytes("RFB 003.003\n") + u32(1) + RFBScript.serverInit(), chunk: 5)
    let outcome = try await performHandshake(transport, password: "ignored")
    #expect(outcome.security == .none)
    // Version, then ClientInit — no security byte, and no SecurityResult on 3.3.
    #expect(transport.written == RFBProtocolVersion.v3_3.encoded + [1])
  }

  @Test(arguments: [UInt32(16), 18, 30, 255])
  func on33AnUnsupportedTypeIsReportedWithThatType(_ type: UInt32) async throws {
    let transport = ScriptedTransport(RFBScript.bytes("RFB 003.003\n") + u32(type), chunk: 4)
    await #expect(throws: RFBError.securityUnsupported([UInt8(clamping: type)])) {
      try await performHandshake(transport, password: "x")
    }
  }

  @Test func on33TypeZeroIsARefusalCarryingItsReason() async throws {
    let transport = ScriptedTransport(
      RFBScript.bytes("RFB 003.003\n") + u32(0) + u32(6) + RFBScript.bytes("Denied"), chunk: 3)
    await #expect(throws: RFBError.authenticationFailed("Denied")) {
      try await performHandshake(transport, password: nil)
    }
  }

  // MARK: SecurityResult

  @Test func securityResultTwoMeansTooManyAttempts() async throws {
    let transport = ScriptedTransport(
      RFBScript.bytes("RFB 003.008\n") + [1, 2] + Self.challenge + u32(2), chunk: 6)
    await #expect(throws: RFBError.authenticationFailed("Too many failed sign-in attempts. Try again later.")) {
      try await performHandshake(transport, password: "x")
    }
  }

  @Test func anUnknownSecurityResultIsMalformed() async throws {
    let transport = ScriptedTransport(
      RFBScript.bytes("RFB 003.008\n") + [1, 2] + Self.challenge + u32(7), chunk: 6)
    await #expect(throws: RFBError.malformed("security result 7")) {
      try await performHandshake(transport, password: "x")
    }
  }

  /// 3.7 has no reason string after a failure, so the client supplies one.
  @Test func on37AFailureHasNoReasonOnTheWire() async throws {
    let transport = ScriptedTransport(
      RFBScript.bytes("RFB 003.007\n") + [1, 2] + Self.challenge + u32(1) + RFBScript.bytes("not read"), chunk: 6)
    await #expect(throws: RFBError.authenticationFailed("The VNC server rejected the password.")) {
      try await performHandshake(transport, password: "x")
    }
  }

  /// 3.7 None skips the SecurityResult entirely: ServerInit follows the pick.
  @Test func on37NoneGoesStraightToServerInit() async throws {
    let transport = ScriptedTransport(
      RFBScript.bytes("RFB 003.007\n") + [2, 1, 2] + RFBScript.serverInit(width: 5, height: 6), chunk: 5)
    let outcome = try await performHandshake(transport, password: nil)
    #expect(outcome.security == .none)
    #expect(outcome.parameters.width == 5 && outcome.parameters.height == 6)
    #expect(transport.written == RFBProtocolVersion.v3_7.encoded + [1, 1])
  }
}
