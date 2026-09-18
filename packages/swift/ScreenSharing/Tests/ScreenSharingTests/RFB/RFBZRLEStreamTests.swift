import Foundation
import Testing
@testable import ScreenSharing

/// ZRLE through the client's read loop, where one zlib stream spans the whole
/// connection: a rectangle is only decodable after every rectangle before it.
struct RFBZRLEStreamTests {
  private func zrle(_ rect: RFBRectangle, _ compressed: [UInt8]) -> [UInt8] {
    RFBScript.rectangle(rect, 16, u32(UInt32(compressed.count)) + compressed)
  }

  private func solidTile(_ blue: UInt8) -> [UInt8] { [1, blue, 0, 0] }

  @Test func consecutiveRectanglesShareOneZlibStream() async throws {
    let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    let deflater = try RFBZlibDeflater()
    let first = try deflater.deflate(solidTile(11))
    let second = try deflater.deflate(solidTile(22))
    let session = try await ScriptedSession.play(
      RFBScript.update([zrle(rect, first)]) + RFBScript.update([zrle(rect, second)]),
      handshake: RFBScript.openHandshake(width: 2, height: 2))
    #expect(session.updates.count == 2)
    #expect(session.updates[0].pixel(x: 1, y: 1) == [11, 0, 0, 255])
    #expect(session.updates[1].pixel(x: 1, y: 1) == [22, 0, 0, 255])
  }

  /// The second rectangle's bytes are meaningless on their own — they continue
  /// a stream whose window and header are in the first. Replaying them alone
  /// must fail rather than paint something arbitrary.
  @Test func aRectangleIsUndecodableWithoutTheOnesBeforeIt() async throws {
    let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    let deflater = try RFBZlibDeflater()
    _ = try deflater.deflate(solidTile(11))
    let second = try deflater.deflate(solidTile(22))
    let session = try await ScriptedSession.play(
      RFBScript.update([zrle(rect, second)]), handshake: RFBScript.openHandshake(width: 2, height: 2))
    #expect(session.error as? RFBError == .malformed("zlib error -3"))
    #expect(session.updates.isEmpty)
  }

  /// Two rectangles inside one update use the same stream in wire order, so
  /// the later one decodes only because the earlier one already did.
  @Test func rectanglesWithinOneUpdateAlsoShareTheStream() async throws {
    let left = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    let right = RFBRectangle(x: 2, y: 0, width: 2, height: 2)
    let deflater = try RFBZlibDeflater()
    let first = try deflater.deflate(solidTile(5))
    let second = try deflater.deflate(solidTile(6))
    let session = try await ScriptedSession.play(
      RFBScript.update([zrle(left, first), zrle(right, second)]),
      handshake: RFBScript.openHandshake(width: 4, height: 2))
    let snapshot = try #require(session.updates.first)
    #expect(snapshot.update.rectangles == [left, right])
    #expect(snapshot.pixel(x: 0, y: 0) == [5, 0, 0, 255])
    #expect(snapshot.pixel(x: 3, y: 1) == [6, 0, 0, 255])
  }

  /// A rectangle spanning several tiles at an offset, compressed as one blob:
  /// the decoder's tile walk and the stream boundary are independent.
  @Test func aMultiTileRectangleArrivesAsOneCompressedBlob() async throws {
    let rect = RFBRectangle(x: 10, y: 6, width: 70, height: 70)
    let tiles = solidTile(1) + solidTile(2) + solidTile(3) + solidTile(4)
    let session = try await ScriptedSession.play(
      RFBScript.update([zrle(rect, try RFBZlibDeflater().deflate(tiles))]),
      handshake: RFBScript.openHandshake(width: 100, height: 100))
    let snapshot = try #require(session.updates.first)
    #expect(snapshot.pixel(x: 10, y: 6) == [1, 0, 0, 255])
    #expect(snapshot.pixel(x: 74, y: 6) == [2, 0, 0, 255])
    #expect(snapshot.pixel(x: 10, y: 70) == [3, 0, 0, 255])
    #expect(snapshot.pixel(x: 79, y: 75) == [4, 0, 0, 255])
    #expect(snapshot.pixel(x: 9, y: 6) == [0, 0, 0, 0])
  }

  /// An empty ZRLE rectangle is a zero-length blob, which decodes to no tiles
  /// and leaves the stream in step for the next rectangle.
  @Test func aZeroLengthZRLERectangleIsAccepted() async throws {
    let empty = RFBRectangle(x: 0, y: 0, width: 0, height: 0)
    let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    let session = try await ScriptedSession.play(
      RFBScript.update([zrle(empty, []), zrle(rect, try RFBZlibDeflater().deflate(solidTile(9)))]),
      handshake: RFBScript.openHandshake(width: 2, height: 2))
    let snapshot = try #require(session.updates.first)
    #expect(snapshot.update.rectangles == [empty, rect])
    #expect(snapshot.pixel(x: 0, y: 0) == [9, 0, 0, 255])
  }

  /// Compressed bytes that inflate to more tile data than the rectangle needs
  /// are a protocol error, not extra pixels for the next rectangle.
  @Test func tileDataBeyondTheRectangleIsMalformed() async throws {
    let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    let session = try await ScriptedSession.play(
      RFBScript.update([zrle(rect, try RFBZlibDeflater().deflate(solidTile(1) + solidTile(2)))]),
      handshake: RFBScript.openHandshake(width: 2, height: 2))
    #expect(session.error as? RFBError == .malformed("ZRLE trailing bytes"))
  }

  @Test func tooLittleTileDataIsMalformed() async throws {
    let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    let session = try await ScriptedSession.play(
      RFBScript.update([zrle(rect, try RFBZlibDeflater().deflate([1, 7, 0]))]),
      handshake: RFBScript.openHandshake(width: 2, height: 2))
    #expect(session.error as? RFBError == .malformed("ZRLE truncated"))
  }

  /// The compressed length is read before the bytes, so a blob cut short by a
  /// dropped connection is a closed connection rather than a decode failure.
  @Test func aTruncatedCompressedBlobEndsTheConnection() async throws {
    let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    let compressed = try RFBZlibDeflater().deflate(solidTile(3))
    let complete = RFBScript.update([zrle(rect, compressed)])
    let session = try await ScriptedSession.play(
      Array(complete.dropLast(2)), handshake: RFBScript.openHandshake(width: 2, height: 2))
    #expect(session.error as? RFBError == .connectionClosed)
  }
}
