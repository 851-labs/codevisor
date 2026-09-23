import Foundation
import Testing
@testable import ScreenSharing

/// ClientInit and ServerInit (RFC 6143 §7.3): the shared flag the client
/// writes, and every field of the twenty-four-byte header plus the name.
struct RFBServerInitTests {
  private func serverInit(
    _ bytes: [UInt8], shared: Bool = true
  ) async throws -> (
    parameters: RFBServerParameters, clientInit: [UInt8]
  ) {
    let transport = ScriptedTransport(RFBScript.bytes("RFB 003.008\n") + [1, 1] + u32(0) + bytes, chunk: 5)
    let outcome = try await performHandshake(transport, password: nil, shared: shared)
    // Everything after the version and the chosen security type is ClientInit.
    return (outcome.parameters, Array(transport.written.dropFirst(13)))
  }

  @Test func theSharedFlagIsOneByteAndFollowsTheSecurityResult() async throws {
    #expect(try await serverInit(RFBScript.serverInit(), shared: true).clientInit == [1])
    #expect(try await serverInit(RFBScript.serverInit(), shared: false).clientInit == [0])
  }

  @Test func widthHeightAndNameAreReadInOrder() async throws {
    let (parameters, _) = try await serverInit(
      RFBScript.serverInit(width: 1920, height: 1080, name: Array("Alexandru’s Mac".utf8)))
    #expect(parameters.width == 1920)
    #expect(parameters.height == 1080)
    #expect(parameters.name == "Alexandru’s Mac")
    #expect(parameters.pixelFormat == .bgra32)
  }

  /// Every pixel-format field comes back verbatim, including the two flags and
  /// a big-endian, palette (non-true-colour) format this client would not use.
  @Test func pixelFormatFieldsSurviveTheRoundTrip() async throws {
    let exotic = RFBPixelFormat(
      bitsPerPixel: 16, depth: 15, bigEndian: true, trueColour: false, redMax: 31, greenMax: 63, blueMax: 1023,
      redShift: 11, greenShift: 5, blueShift: 0)
    #expect(exotic.encoded == [UInt8](hex: "10 0f 01 00 001f 003f 03ff 0b 05 00 000000"))
    let (parameters, _) = try await serverInit(RFBScript.serverInit(format: exotic))
    #expect(parameters.pixelFormat == exotic)
    #expect(parameters.pixelFormat.bytesPerPixel == 2)
  }

  @Test func theThreeTrailingPaddingBytesAreIgnored() throws {
    var noisy = RFBPixelFormat.bgra32.encoded
    noisy[13] = 0xde
    noisy[14] = 0xad
    noisy[15] = 0xbe
    #expect(try RFBPixelFormat.decode(noisy) == .bgra32)
  }

  /// Any non-zero byte is true, not only 1 — servers in the wild send 0xff.
  @Test func flagsAreTrueForAnyNonZeroByte() throws {
    var flagged = RFBPixelFormat.bgra32.encoded
    flagged[2] = 0xff
    flagged[3] = 0x02
    let decoded = try RFBPixelFormat.decode(flagged)
    #expect(decoded.bigEndian)
    #expect(decoded.trueColour)
  }

  @Test(arguments: [0, 1, 15, 17, 32])
  func aPixelFormatIsExactlySixteenBytes(_ count: Int) {
    #expect(throws: RFBError.malformed("pixel format is \(count) bytes")) {
      try RFBPixelFormat.decode([UInt8](repeating: 0, count: count))
    }
  }

  @Test(arguments: [0, 1, 3, 255])
  func namesOfAnyLengthIncludingZeroAreRead(_ length: Int) async throws {
    let name = [UInt8](repeating: UInt8(ascii: "n"), count: length)
    let (parameters, _) = try await serverInit(RFBScript.serverInit(name: name))
    #expect(parameters.name == String(repeating: "n", count: length))
  }

  /// The name is bytes, not text: invalid UTF-8 becomes replacement characters
  /// rather than failing the connection.
  @Test func anInvalidUTF8NameBecomesReplacementCharacters() async throws {
    let (parameters, _) = try await serverInit(RFBScript.serverInit(name: [0x41, 0xff, 0xfe, 0x42]))
    #expect(parameters.name == "A\u{fffd}\u{fffd}B")
  }

  @Test func aNameLongerThanTheStreamEndsTheConnection() async throws {
    await #expect(throws: RFBError.connectionClosed) {
      try await serverInit(RFBScript.serverInit(name: Array("short".utf8), declaredNameLength: 64))
    }
    await #expect(throws: RFBError.connectionClosed) {
      try await serverInit(RFBScript.serverInit(name: [], declaredNameLength: .max))
    }
  }

  /// Every prefix of a valid ServerInit ends the same way: there is no field
  /// boundary at which a short read is mistaken for a value.
  @Test func everyTruncationOfServerInitIsAClosedConnection() async throws {
    let complete = RFBScript.serverInit(width: 800, height: 600, name: Array("Desk".utf8))
    for length in 0..<complete.count {
      await #expect(throws: RFBError.connectionClosed, "truncated after \(length) bytes") {
        try await serverInit(Array(complete.prefix(length)))
      }
    }
    let (parameters, _) = try await serverInit(complete)
    #expect(parameters == RFBServerParameters(width: 800, height: 600, pixelFormat: .bgra32, name: "Desk"))
  }

  /// The client sizes its framebuffer from ServerInit, so a server claiming a
  /// desktop it cannot render fails the connection rather than the first paint.
  @Test(arguments: [(0, 100), (100, 0), (0, 0)])
  func aDegenerateDesktopSizeFailsTheConnect(_ width: Int, _ height: Int) async throws {
    let transport = ScriptedTransport(
      RFBScript.openHandshake(width: width, height: height), chunk: 5)
    let client = try RFBClient(transport: transport)
    await #expect(throws: RFBError.malformed("framebuffer \(width) × \(height)")) {
      try await client.connect(password: nil)
    }
  }

  /// A successful connect resizes the framebuffer and immediately states the
  /// format and encodings this client understands.
  @Test func connectSizesTheFramebufferThenStatesFormatAndEncodings() async throws {
    let transport = ScriptedTransport(RFBScript.openHandshake(width: 320, height: 200), chunk: 5)
    let client = try RFBClient(transport: transport)
    let outcome = try await client.connect(password: nil)
    #expect(outcome.parameters.width == 320)
    #expect(client.framebuffer.width == 320 && client.framebuffer.height == 200)
    #expect(client.framebuffer.pixels.count == 320 * 200 * 4)
    let encodings: [Int32] = [7, 16, 1, 0, -223, -239, -232, -312, -313, -308, -1_063_131_698]
    let expected: [UInt8] =
      RFBClientMessage.setPixelFormat(.bgra32).encoded + RFBClientMessage.setEncodings(encodings).encoded
    #expect(Array(transport.written.dropFirst(14)) == expected)
  }
}
