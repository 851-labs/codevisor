import Foundation
import Testing
@testable import ScreenSharing

struct RFBMessageTests {
  @Test func protocolVersionRoundTrips() {
    #expect(RFBProtocolVersion.parse(Array("RFB 003.008\n".utf8)) == .v3_8)
    #expect(RFBProtocolVersion.parse(Array("RFB 003.889\n".utf8)) == RFBProtocolVersion(major: 3, minor: 889))
    #expect(RFBProtocolVersion.parse(Array("HTTP/1.1 200\n".utf8)) == nil)
    #expect(RFBProtocolVersion.v3_7.encoded == Array("RFB 003.007\n".utf8))
    #expect(RFBProtocolVersion(major: 3, minor: 889) > .v3_8)
  }

  @Test func pixelFormatRoundTripsAsSixteenBytes() throws {
    let bytes = RFBPixelFormat.bgra32.encoded
    #expect(bytes == [UInt8](hex: "20 18 00 01 00ff 00ff 00ff 10 08 00 000000"))
    #expect(try RFBPixelFormat.decode(bytes) == .bgra32)
    #expect(throws: RFBError.self) { try RFBPixelFormat.decode([1, 2, 3]) }
  }

  @Test func clientMessagesMatchTheWireFormat() {
    #expect(
      RFBClientMessage.setEncodings([16, 1, 0, -223]).encoded
        == [2, 0, 0, 4] + u32(16) + u32(1) + u32(0) + u32(UInt32(bitPattern: -223)))
    #expect(
      RFBClientMessage.framebufferUpdateRequest(incremental: true, RFBRectangle(x: 1, y: 2, width: 300, height: 400))
        .encoded == [3, 1] + u16(1) + u16(2) + u16(300) + u16(400))
    #expect(RFBClientMessage.keyEvent(keysym: 0xff0d, down: true).encoded == [4, 1, 0, 0, 0, 0, 0xff, 0x0d])
    #expect(RFBClientMessage.pointerEvent(buttons: 0b101, x: 640, y: 10).encoded == [5, 5] + u16(640) + u16(10))
    #expect(
      RFBClientMessage.clientCutText("héllo\r\n€").encoded == [6, 0, 0, 0] + u32(7) + [UInt8](hex: "68e96c6c6f0a3f"))
    #expect(RFBClientMessage.setPixelFormat(.bgra32).encoded == [0, 0, 0, 0] + RFBPixelFormat.bgra32.encoded)
  }

  @Test func clientMessagesAreReadBackByTheServerSide() async throws {
    let messages: [RFBClientMessage] = [
      .setPixelFormat(.bgra32), .setEncodings([16, -223]),
      .framebufferUpdateRequest(incremental: false, RFBRectangle(x: 0, y: 0, width: 8, height: 8)),
      .keyEvent(keysym: 0x61, down: false), .pointerEvent(buttons: 1, x: 3, y: 4), .clientCutText("copy\n"),
    ]
    let stream = RFBInputStream(transport: ScriptedTransport(messages.flatMap(\.encoded), chunk: 5))
    for message in messages { #expect(try await RFBClientMessage.read(from: stream) == message) }
  }

  @Test func latin1IsLossyAndNormalisesLineEndings() {
    #expect(RFBLatin1.encode("a\r\nb→") == [0x61, 0x0a, 0x62, 0x3f])
    #expect(RFBLatin1.decode([0xe9, 0x0d, 0x0a, 0x41]) == "é\nA")
  }

  @Test func keysymsFollowTheX11Convention() {
    #expect(RFBKeysym.keysym(for: "a") == 0x61)
    #expect(RFBKeysym.keysym(for: "é") == 0xe9)
    #expect(RFBKeysym.keysym(for: "→") == 0x0100_2192)
    #expect(RFBKeysym.keysym(for: "\r") == RFBKeysym.return)
    #expect(RFBKeysym.keysym(for: "\u{7f}") == RFBKeysym.delete)
    #expect(RFBKeysym.keysym(for: "\u{03}") == 0x43)  // Control-C arrives as the letter
    #expect(RFBKeysym.function(12) == 0xffc9)
  }

  @Test func vncAuthenticationMatchesAnIndependentDES() {
    // openssl enc -des-ecb -nopad with the bit-reversed key of "secret".
    let response = RFBVNCAuthentication.response(challenge: [UInt8](0..<16), password: "secret")
    #expect(response == [UInt8](hex: "ee22539f33a5983ec12f9c2edbc995dd"))
    // Only the first eight bytes of the password are the key.
    #expect(
      RFBVNCAuthentication.response(challenge: [UInt8](0..<16), password: "secret12-and-more")
        == RFBVNCAuthentication.response(challenge: [UInt8](0..<16), password: "secret12"))
    #expect(RFBVNCAuthentication.response(challenge: [UInt8](0..<16), password: "other") != response)
  }
}
