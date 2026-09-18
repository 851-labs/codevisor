import Foundation
import Testing
@testable import ScreenSharing

/// ProtocolVersion (RFC 6143 §7.1.1): the twelve bytes each side sends, which
/// greetings parse, and which version the client answers with.
struct RFBVersionNegotiationTests {
  @Test func supportedVersionsEncodeToTheTwelveByteGreeting() {
    #expect(RFBProtocolVersion.v3_3.encoded == Array("RFB 003.003\n".utf8))
    #expect(RFBProtocolVersion.v3_7.encoded == Array("RFB 003.007\n".utf8))
    #expect(RFBProtocolVersion.v3_8.encoded == Array("RFB 003.008\n".utf8))
    #expect(RFBProtocolVersion.v3_8.encoded.count == 12)
    #expect(RFBProtocolVersion(major: 3, minor: 889).description == "RFB 003.889\n")
    // Three digits each, so a version above 999 would no longer be twelve bytes.
    #expect(RFBProtocolVersion(major: 3, minor: 7).encoded == RFBProtocolVersion.v3_7.encoded)
  }

  @Test(arguments: [
    ("RFB 003.003\n", 3, 3), ("RFB 003.007\n", 3, 7), ("RFB 003.008\n", 3, 8), ("RFB 003.889\n", 3, 889),
    ("RFB 004.001\n", 4, 1), ("RFB 000.000\n", 0, 0), ("RFB 999.999\n", 999, 999),
  ])
  func wellFormedGreetingsParse(_ text: String, _ major: Int, _ minor: Int) {
    #expect(RFBProtocolVersion.parse(Array(text.utf8)) == RFBProtocolVersion(major: major, minor: minor))
  }

  @Test(arguments: [
    "",  // nothing at all
    "RFB 003.008",  // no newline, eleven bytes
    "RFB 03.008\n",  // eleven bytes: a digit short
    "RFB 0003.008\n",  // thirteen bytes: a digit too many
    "RFB 003.008\n\n",  // trailing byte
    "RFB 003.008 ",  // terminated with a space
    "RFB 003x008\n",  // separator is not a dot
    "RFB abc.008\n",  // non-numeric major
    "RFB 003.abc\n",  // non-numeric minor
    "RFB  03.008\n",  // whitespace where a digit belongs
    "VNC 003.008\n",  // wrong magic
    "rfb 003.008\n",  // magic is case sensitive
    "RFB\t003.008\n",  // magic must end in a space
  ])
  func malformedGreetingsDoNotParse(_ text: String) {
    #expect(RFBProtocolVersion.parse(Array(text.utf8)) == nil)
  }

  @Test func versionsOrderByMajorThenMinor() {
    #expect(RFBProtocolVersion.v3_3 < .v3_7)
    #expect(RFBProtocolVersion.v3_7 < .v3_8)
    #expect(RFBProtocolVersion(major: 3, minor: 889) > .v3_8)
    #expect(RFBProtocolVersion(major: 4, minor: 0) > RFBProtocolVersion(major: 3, minor: 999))
    #expect(RFBProtocolVersion(major: 3, minor: 8) == .v3_8)
  }

  /// The client answers with the newest version both sides speak, never with
  /// the server's own if that is newer than 3.8.
  @Test(arguments: [
    ("RFB 003.003\n", RFBProtocolVersion.v3_3), ("RFB 003.004\n", .v3_3), ("RFB 003.006\n", .v3_3),
    ("RFB 003.007\n", .v3_7), ("RFB 003.008\n", .v3_8), ("RFB 003.889\n", .v3_8), ("RFB 004.001\n", .v3_8),
    ("RFB 010.000\n", .v3_8),
  ])
  func theClientAnswersWithTheNewestVersionBothSidesSpeak(
    _ greeting: String, _ expected: RFBProtocolVersion
  ) async throws {
    // None security, then the security result 3.8 alone expects.
    let security: [UInt8] = expected == .v3_3 ? u32(1) : [1, 1] + (expected == .v3_8 ? u32(0) : [])
    let transport = ScriptedTransport(RFBScript.bytes(greeting) + security + RFBScript.serverInit(), chunk: 5)
    let outcome = try await performHandshake(transport, password: nil)
    #expect(outcome.version == expected)
    #expect(Array(transport.written.prefix(12)) == expected.encoded)
  }

  @Test(arguments: [
    ("RFB 003.002\n", "unsupported version 3.2"), ("RFB 002.009\n", "unsupported version 2.9"),
    ("RFB 000.000\n", "unsupported version 0.0"),
  ])
  func versionsOlderThan33AreRejectedWithoutWritingAnything(_ greeting: String, _ detail: String) async throws {
    let transport = ScriptedTransport(RFBScript.bytes(greeting) + [1, 1], chunk: 4)
    await #expect(throws: RFBError.protocolMismatch(detail)) { try await performHandshake(transport, password: nil) }
    #expect(transport.written.isEmpty)
  }

  @Test(arguments: ["SSH-2.0-OpenSSH_9\n", "HTTP/1.1 400 Bad\n", "RFB 003.008", "\0\0\0\0\0\0\0\0\0\0\0\0"])
  func nonRFBGreetingsAreAMismatch(_ greeting: String) async throws {
    let transport = ScriptedTransport(RFBScript.bytes(greeting) + [1, 1] + u32(0), chunk: 6)
    await #expect(throws: RFBError.protocolMismatch("no RFB greeting")) {
      try await performHandshake(transport, password: nil)
    }
    #expect(transport.written.isEmpty)
  }

  @Test func aGreetingCutShortIsAClosedConnectionNotAMismatch() async throws {
    let transport = ScriptedTransport(RFBScript.bytes("RFB 003."), chunk: 3)
    await #expect(throws: RFBError.connectionClosed) { try await performHandshake(transport, password: nil) }
  }
}
