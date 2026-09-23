import CodevisorTestSupport
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

/// The Cursor (-239) and PointerPos (-232) pseudo-encodings (851-2311): the
/// pointer's shape is drawn locally, and a server-side move is reported.
struct RFBCursorTests {
  typealias Harness = RFBClientLoopbackTests.Harness

  /// A 3 × 2 shape: an opaque red top row, then a single opaque blue pixel.
  static let shape = RFBCursorShape(
    width: 3, height: 2, hotspotX: 1, hotspotY: 0,
    pixels: [0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0])

  // MARK: L1 — bytes to shape

  @Test func theMaskDecidesWhichPixelsAreOpaque() throws {
    // Pixels (colour everywhere, even where the mask hides it), then one mask byte per row.
    let colour: [UInt8] = [9, 9, 9, 0]
    let mask: [UInt8] = [0b1010_0000, 0b0100_0000]
    let payload: [UInt8] = Array(repeating: colour, count: 6).flatMap { $0 } + mask
    let shape = try RFBCursorShape.decode(width: 3, height: 2, hotspotX: 2, hotspotY: 1, payload: payload)
    let alpha = stride(from: 3, to: shape.pixels.count, by: 4).map { shape.pixels[$0] }
    #expect(alpha == [255, 0, 255, 0, 255, 0])
    #expect(Array(shape.pixels[4..<8]) == [0, 0, 0, 0], "Masked-out pixels are fully transparent, colour included.")
    #expect(Array(shape.pixels[0..<3]) == [9, 9, 9])
    #expect((shape.hotspotX, shape.hotspotY) == (2, 1))
  }

  @Test func encodingAndDecodingRoundTrip() throws {
    let payload = Self.shape.encodedPayload()
    #expect(payload.count == 3 * 2 * 4 + RFBCursorShape.maskLength(width: 3, height: 2))
    #expect(try RFBCursorShape.decode(width: 3, height: 2, hotspotX: 1, hotspotY: 0, payload: payload) == Self.shape)
  }

  @Test func anEmptyShapeHidesThePointer() throws {
    #expect(try RFBCursorShape.decode(width: 0, height: 0, hotspotX: 0, hotspotY: 0, payload: []).isHidden)
  }

  @Test func malformedShapesAreRejectedAndEdgeHotspotsClamped() throws {
    #expect(throws: RFBError.self) {
      try RFBCursorShape.decode(width: 2, height: 2, hotspotX: 0, hotspotY: 0, payload: [1, 2, 3])
    }
    #expect(throws: RFBError.self) {
      try RFBCursorShape.decode(width: 1024, height: 2, hotspotX: 0, hotspotY: 0, payload: [])
    }
    let edge = try RFBCursorShape.decode(
      width: 1, height: 1, hotspotX: 5, hotspotY: 1, payload: [1, 2, 3, 0, 0b1000_0000])
    #expect((edge.hotspotX, edge.hotspotY) == (0, 0))
  }

  @Test func theReferenceArrowSurvivesTheWire() throws {
    let arrow = RFBCursorShape.referenceArrow
    #expect(arrow.pixels.count == 11 * 16 * 4)
    let decoded = try RFBCursorShape.decode(
      width: 11, height: 16, hotspotX: 0, hotspotY: 0, payload: arrow.encodedPayload())
    #expect(decoded == arrow)
  }

  // MARK: L2 — against the reference server

  @Test func theClientAdvertisesCursorAndPointerPosition() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    _ = try #require(await harness.nextUpdate())
    #expect(harness.server.advertisedEncodings.isSuperset(of: [-239, -232]))
  }

  @Test func theConfiguredShapeArrivesWithTheFirstUpdate() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.cursor = Self.shape
    let harness = try await Harness(configuration: configuration)
    defer { harness.stop() }
    let first = try #require(await harness.nextUpdate())
    #expect(first.update.cursor == Self.shape)
    #expect(
      first.update.rectangles == [RFBRectangle(x: 0, y: 0, width: 64, height: 48)],
      "The cursor isn't a framebuffer change.")
  }

  @Test func shapeChangesAndServerSideMovesArriveAsTheyHappen() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let first = try #require(await harness.nextUpdate())
    #expect(first.update.cursor == nil && first.update.pointer == nil)
    harness.server.setCursor(.hidden)
    #expect(try #require(await harness.nextUpdate()).update.cursor == .hidden)
    harness.server.movePointer(to: RFBPoint(x: 30, y: 12))
    let moved = try #require(await harness.nextUpdate())
    #expect(moved.update.pointer == RFBPoint(x: 30, y: 12))
    #expect(moved.update.rectangles.isEmpty)
  }
}
