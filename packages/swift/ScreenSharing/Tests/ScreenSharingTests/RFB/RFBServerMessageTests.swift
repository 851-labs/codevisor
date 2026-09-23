import Foundation
import Testing
@testable import ScreenSharing

/// Every server-to-client message (RFC 6143 §7.6) through the client's read
/// loop, over a scripted stream that ends on its own so nothing is timed.
struct RFBServerMessageTests {
  private static let square = RFBRectangle(x: 0, y: 0, width: 2, height: 2)

  @Test func theReadLoopAsksForTheWholeScreenBeforeReadingAnything() async throws {
    let session = try await ScriptedSession.play([], handshake: RFBScript.openHandshake(width: 320, height: 200))
    #expect(session.error as? RFBError == .connectionClosed)
    #expect(
      Array(session.written.suffix(10))
        == RFBClientMessage.framebufferUpdateRequest(
          incremental: false, RFBRectangle(x: 0, y: 0, width: 320, height: 200)
        ).encoded)
  }

  @Test func bellIsASingleByte() async throws {
    let session = try await ScriptedSession.play([2, 2, 2])
    #expect(session.events == [.bell, .bell, .bell])
    #expect(session.error as? RFBError == .connectionClosed)
  }

  @Test func serverCutTextIsLatin1WithNormalisedLineEndings() async throws {
    let text: [UInt8] = [0x61, 0x0d, 0x0a, 0x62, 0xe9]
    let session = try await ScriptedSession.play([3, 0, 0, 0] + u32(UInt32(text.count)) + text + [2])
    #expect(session.events == [.serverCutText("a\nbé"), .bell])
  }

  @Test func anEmptyServerCutTextStillArrives() async throws {
    let session = try await ScriptedSession.play([3, 0, 0, 0] + u32(0) + [2])
    #expect(session.events == [.serverCutText(""), .bell])
  }

  /// A negative length is an Extended Clipboard message (851-2316); one the
  /// client can't decode (here: flags with no action) is dropped whole, so the
  /// stream stays in sync and the session carries on.
  @Test func anUndecodableExtendedClipboardMessageIsSkippedWhole() async throws {
    let body: [UInt8] = [0, 0, 0, 1] + [UInt8](repeating: 0x55, count: 36)
    let session = try await ScriptedSession.play(
      [3, 0, 0, 0] + s32(-40) + body + [2] + [3, 0, 0, 0] + u32(2) + RFBScript.bytes("ok"))
    #expect(session.events == [.bell, .serverCutText("ok")])
  }

  @Test func aDecodableExtendedClipboardMessageIsDelivered() async throws {
    let body = try RFBExtendedClipboard.encode(.notify(formats: RFBExtendedClipboard.text))
    let session = try await ScriptedSession.play([3, 0, 0, 0] + s32(-Int32(body.count)) + body + [2])
    #expect(session.events == [.extendedClipboard(.notify(formats: RFBExtendedClipboard.text)), .bell])
  }

  /// SetColourMapEntries is six bytes per colour after a six-byte header; the
  /// client has no use for it but must step over exactly the right number.
  @Test(arguments: [0, 1, 256])
  func setColourMapEntriesIsSkippedByItsColourCount(_ colours: Int) async throws {
    let message: [UInt8] =
      [1, 0] + u16(0) + u16(UInt16(colours)) + [UInt8](repeating: 0xcc, count: colours * 6)
    let session = try await ScriptedSession.play(message + [2])
    #expect(session.events == [.bell])
    #expect(session.error as? RFBError == .connectionClosed)
  }

  @Test(arguments: [UInt8(4), 5, 127, 200, 255])
  func anUnknownServerMessageTypeIsTerminal(_ type: UInt8) async throws {
    let session = try await ScriptedSession.play([type])
    #expect(session.error as? RFBError == .malformed("unknown server message \(type)"))
  }

  // MARK: FramebufferUpdate

  @Test func rawRectanglesLandAtTheirOffsetWithAnOpaqueAlpha() async throws {
    let rect = RFBRectangle(x: 1, y: 2, width: 2, height: 2)
    let session = try await ScriptedSession.play(
      RFBScript.update([RFBScript.rectangle(rect, 0, RFBScript.rawPixels(rect, blue: 10, green: 20, red: 30))]),
      handshake: RFBScript.openHandshake(width: 4, height: 5))
    let snapshot = try #require(session.updates.first)
    #expect(snapshot.update == RFBUpdate(rectangles: [rect], resized: false))
    #expect(snapshot.pixel(x: 1, y: 2) == [10, 20, 30, 255])
    #expect(snapshot.pixel(x: 2, y: 3) == [10, 20, 30, 255])
    #expect(snapshot.pixel(x: 0, y: 2) == [0, 0, 0, 0])
    #expect(snapshot.pixel(x: 3, y: 2) == [0, 0, 0, 0])
  }

  /// An update is acknowledged with one incremental request, and only one:
  /// the client keeps a single request in flight.
  @Test func eachAppliedUpdateIsFollowedByOneIncrementalRequest() async throws {
    let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    let one = RFBScript.update([RFBScript.rectangle(rect, 0, RFBScript.rawPixels(rect, blue: 1, green: 1, red: 1))])
    let session = try await ScriptedSession.play(
      one + one, handshake: RFBScript.openHandshake(width: 2, height: 2))
    let request = RFBClientMessage.framebufferUpdateRequest(incremental: true, rect).encoded
    #expect(session.updates.count == 2)
    #expect(Array(session.written.suffix(request.count * 2)) == request + request)
  }

  @Test func anUpdateWithNoRectanglesIsStillAnUpdate() async throws {
    let session = try await ScriptedSession.play(RFBScript.update([]))
    #expect(session.updates.map(\.update) == [RFBUpdate(rectangles: [], resized: false)])
  }

  @Test func severalRectanglesInOneUpdateAreReportedTogether() async throws {
    let left = RFBRectangle(x: 0, y: 0, width: 1, height: 1), right = RFBRectangle(x: 1, y: 0, width: 1, height: 1)
    let session = try await ScriptedSession.play(
      RFBScript.update([
        RFBScript.rectangle(left, 0, RFBScript.rawPixels(left, blue: 1, green: 2, red: 3)),
        RFBScript.rectangle(right, 0, RFBScript.rawPixels(right, blue: 4, green: 5, red: 6)),
      ]), handshake: RFBScript.openHandshake(width: 2, height: 1))
    let snapshot = try #require(session.updates.first)
    #expect(snapshot.update.rectangles == [left, right])
    #expect(snapshot.pixel(x: 0, y: 0) == [1, 2, 3, 255])
    #expect(snapshot.pixel(x: 1, y: 0) == [4, 5, 6, 255])
  }

  @Test func copyRectMovesPixelsAlreadyInTheFramebuffer() async throws {
    let source = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    let destination = RFBRectangle(x: 2, y: 2, width: 2, height: 2)
    let session = try await ScriptedSession.play(
      RFBScript.update([RFBScript.rectangle(source, 0, RFBScript.rawPixels(source, blue: 7, green: 8, red: 9))])
        + RFBScript.update([RFBScript.rectangle(destination, 1, u16(0) + u16(0))]),
      handshake: RFBScript.openHandshake(width: 4, height: 4))
    #expect(session.updates.count == 2)
    let copied = try #require(session.updates.last)
    #expect(copied.update.rectangles == [destination])
    #expect(copied.pixel(x: 3, y: 3) == [7, 8, 9, 255])
    #expect(copied.pixel(x: 0, y: 0) == [7, 8, 9, 255])
  }

  /// CopyRect whose source and destination overlap: a one-pixel shift down the
  /// framebuffer must not smear the top row over everything below it.
  @Test func copyRectHandlesOverlappingSourceAndDestination() async throws {
    let rows = (0..<4).map { row in
      RFBScript.rectangle(
        RFBRectangle(x: 0, y: row, width: 1, height: 1), 0,
        RFBScript.rawPixels(RFBRectangle(x: 0, y: 0, width: 1, height: 1), blue: UInt8(row + 1), green: 0, red: 0))
    }
    let session = try await ScriptedSession.play(
      RFBScript.update(rows)
        + RFBScript.update([RFBScript.rectangle(RFBRectangle(x: 0, y: 1, width: 1, height: 3), 1, u16(0) + u16(0))])
        + RFBScript.update([RFBScript.rectangle(RFBRectangle(x: 0, y: 0, width: 1, height: 3), 1, u16(0) + u16(1))]),
      handshake: RFBScript.openHandshake(width: 1, height: 4))
    #expect(session.updates.count == 3)
    #expect((0..<4).map { session.updates[0].pixel(x: 0, y: $0)[0] } == [1, 2, 3, 4])
    #expect((0..<4).map { session.updates[1].pixel(x: 0, y: $0)[0] } == [1, 1, 2, 3])  // shifted down
    #expect((0..<4).map { session.updates[2].pixel(x: 0, y: $0)[0] } == [1, 2, 3, 3])  // shifted back up
  }

  @Test func desktopSizeResizesAndIsReportedWithoutARectangle() async throws {
    let session = try await ScriptedSession.play(
      RFBScript.update([RFBScript.rectangle(RFBRectangle(x: 0, y: 0, width: 8, height: 4), -223)]),
      handshake: RFBScript.openHandshake(width: 2, height: 2))
    let snapshot = try #require(session.updates.first)
    #expect(snapshot.update == RFBUpdate(rectangles: [], resized: true))
    #expect(snapshot.width == 8 && snapshot.height == 4)
    // The next request covers the new desktop, not the old one.
    #expect(
      Array(session.written.suffix(10))
        == RFBClientMessage.framebufferUpdateRequest(
          incremental: true, RFBRectangle(x: 0, y: 0, width: 8, height: 4)
        ).encoded)
  }

  @Test(arguments: [Int32(2), 5, 8, -240, -314, Int32.max, Int32.min])
  func anEncodingTheClientNeverAskedForIsTerminal(_ encoding: Int32) async throws {
    let session = try await ScriptedSession.play(
      RFBScript.update([RFBScript.rectangle(Self.square, encoding)]),
      handshake: RFBScript.openHandshake(width: 2, height: 2))
    #expect(session.error as? RFBError == .unsupportedEncoding(encoding))
    #expect(session.updates.isEmpty)
  }

  @Test func aRectangleOutsideTheFramebufferIsMalformed() async throws {
    let outside = RFBRectangle(x: 6, y: 0, width: 4, height: 1)
    let session = try await ScriptedSession.play(
      RFBScript.update([RFBScript.rectangle(outside, 0, RFBScript.rawPixels(outside, blue: 0, green: 0, red: 0))]),
      handshake: RFBScript.openHandshake(width: 8, height: 4))
    #expect(session.error as? RFBError == .malformed("rectangle \(outside) outside 8 × 4"))
  }

  @Test func aCopyRectFromOutsideTheFramebufferIsMalformed() async throws {
    let session = try await ScriptedSession.play(
      RFBScript.update([RFBScript.rectangle(Self.square, 1, u16(7) + u16(0))]),
      handshake: RFBScript.openHandshake(width: 8, height: 4))
    #expect(
      session.error as? RFBError
        == .malformed("rectangle \(RFBRectangle(x: 7, y: 0, width: 2, height: 2)) outside 8 × 4"))
  }

  /// A ZRLE length a server could never mean is refused before the bytes are
  /// read, so a hostile header cannot make the client buffer 4 GB.
  @Test func anAbsurdZRLELengthIsRefusedBeforeReading() async throws {
    let session = try await ScriptedSession.play(
      RFBScript.update([RFBScript.rectangle(Self.square, 16, u32(64 << 20 + 1))]),
      handshake: RFBScript.openHandshake(width: 2, height: 2))
    #expect(session.error as? RFBError == .malformed("ZRLE rectangle of \(64 << 20 + 1) bytes"))
  }

  /// Every prefix of a valid update ends the run with a closed connection:
  /// no truncation is mistaken for a complete rectangle.
  @Test func everyTruncationOfAnUpdateEndsTheRun() async throws {
    let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    let complete = RFBScript.update([
      RFBScript.rectangle(rect, 0, RFBScript.rawPixels(rect, blue: 3, green: 3, red: 3))
    ])
    for length in 0..<complete.count {
      let session = try await ScriptedSession.play(
        Array(complete.prefix(length)), handshake: RFBScript.openHandshake(width: 2, height: 2))
      #expect(session.error as? RFBError == .connectionClosed, "truncated after \(length) bytes")
      #expect(session.updates.isEmpty, "truncated after \(length) bytes")
    }
  }
}
