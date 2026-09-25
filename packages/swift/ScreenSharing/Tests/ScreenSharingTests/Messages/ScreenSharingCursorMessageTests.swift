import AppKit
import Foundation
import Testing
@testable import ScreenSharing

/// The cursor stream's wire format and the host's publisher (851-2377).
@MainActor
struct ScreenSharingCursorMessageTests {
  /// A 4 × 6 image: opaque red, hotspot (1, 2), drawn by the host at 2× of a 2 × 3-point cursor.
  static func redImage() throws -> ScreenSharingCursorImage {
    let png = try #require(
      ScreenSharingCursorImage.png(pixelWidth: 4, pixelHeight: 6) { context in
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
      })
    return ScreenSharingCursorImage(png: png, hotspotX: 1, hotspotY: 2, width: 0.01, height: 0.02)
  }

  @Test func everyMessageSurvivesTheWire() throws {
    let image = try Self.redImage()
    for message: ScreenSharingCursorMessage in [
      .subscribe, .shape(image), .position(ScreenSharingPointer(x: 0.25, y: 0.75)), .position(nil),
    ] {
      #expect(try ScreenSharingCursorMessage.decode(message.encoded()) == message)
    }
  }

  @Test func anotherVersionOrAnOversizedMessageIsRefused() throws {
    let future = Data(#"{"version":2,"message":{"subscribe":{}}}"#.utf8)
    #expect(throws: ScreenSharingError.self) { try ScreenSharingCursorMessage.decode(future) }
    let huge = ScreenSharingCursorImage(
      png: Data(count: ScreenSharingCursorMessage.maximumBytes), hotspotX: 0, hotspotY: 0, width: 1, height: 1)
    #expect(throws: ScreenSharingError.self) { try ScreenSharingCursorMessage.shape(huge).encoded() }
    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingCursorMessage.decode(Data(count: ScreenSharingCursorMessage.maximumBytes + 1))
    }
  }

  @Test func anImageBecomesAPremultipliedBGRAShape() throws {
    let shape = try #require(try Self.redImage().shape())
    #expect(shape.width == 4 && shape.height == 6 && shape.hotspotX == 1 && shape.hotspotY == 2)
    #expect(Array(shape.pixels.prefix(4)) == [0, 0, 255, 255], "B, G, R, A")
    #expect(!shape.isInvisible)
  }

  @Test func imagesThatCantBeDrawnAreRefused() throws {
    var image = try Self.redImage()
    image.hotspotX = 4
    #expect(image.shape() == nil, "hotspot outside the image")
    image.hotspotX = 0
    image.png = Data("not a png".utf8)
    #expect(image.shape() == nil)
    let big = try #require(ScreenSharingCursorImage.png(pixelWidth: 257, pixelHeight: 1) { _ in })
    #expect(ScreenSharingCursorImage(png: big, hotspotX: 0, hotspotY: 0, width: 1, height: 1).shape() == nil)
  }

  // MARK: Publisher

  @MainActor final class Host {
    var location = CGPoint(x: 150, y: 125)
    var image = Host.cursor(width: 10, height: 16)
    var hotSpot = CGPoint(x: 2, y: 3)
    var sent: [ScreenSharingCursorMessage] = []
    var refuse = false
    /// A 1000 × 500-point display at (100, 100), 2×.
    lazy var publisher = ScreenSharingCursorPublisher(
      bounds: { CGRect(x: 100, y: 100, width: 1000, height: 500) }, scale: { 2 },
      pointer: { [unowned self] in .init(location: location, image: image, hotSpot: hotSpot) },
      send: { [unowned self] message in
        guard !refuse else { return false }
        sent.append(message)
        return true
      })

    static func cursor(width: CGFloat, height: CGFloat, color: NSColor = .black) -> NSImage {
      NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        color.setFill()
        rect.fill()
        return true
      }
    }

    var positions: [ScreenSharingPointer?] {
      sent.compactMap { if case .position(let pointer) = $0 { pointer } else { nil } }
    }
    var shapes: [ScreenSharingCursorImage] {
      sent.compactMap { if case .shape(let image) = $0 { image } else { nil } }
    }
  }

  @Test func theFirstTickSendsTheShapeThenThePosition() throws {
    let host = Host()
    host.publisher.tick()
    let shape = try #require(host.shapes.first)
    #expect(host.sent.count == 2)
    #expect(host.positions == [ScreenSharingPointer(x: 0.05, y: 0.05)])
    // 2×: 20 × 32 pixels with the hotspot doubled, sized as a share of the display.
    let drawn = try #require(shape.shape())
    #expect(drawn.width == 20 && drawn.height == 32)
    #expect(shape.hotspotX == 4 && shape.hotspotY == 6)
    #expect(shape.width == 0.01 && shape.height == 0.032)
  }

  @Test func onlyChangesAreSent() {
    let host = Host()
    host.publisher.tick()
    for _ in 0..<5 { host.publisher.tick() }
    #expect(host.sent.count == 2, "nothing moved, nothing changed")
    host.location = CGPoint(x: 600, y: 350)
    host.publisher.tick()
    #expect(host.positions.last == ScreenSharingPointer(x: 0.5, y: 0.5))
    // Shapes are looked at every third tick: a change shows up within three.
    host.image = Host.cursor(width: 10, height: 16, color: .white)
    for _ in 0..<ScreenSharingCursorPublisher.shapeEvery { host.publisher.tick() }
    #expect(host.shapes.count == 2)
  }

  @Test func aPointerOnAnotherDisplayIsSentAsAbsentOnce() {
    let host = Host()
    host.publisher.tick()
    host.location = CGPoint(x: 50, y: 50)
    host.publisher.tick()
    host.publisher.tick()
    #expect(host.positions == [ScreenSharingPointer(x: 0.05, y: 0.05), nil])
    #expect(
      ScreenSharingCursorPublisher.position(
        CGPoint(x: 1100, y: 600), in: CGRect(x: 100, y: 100, width: 1000, height: 500))
        == ScreenSharingPointer(x: 1, y: 1))
  }

  @Test func whatTheChannelRefusedIsSentAgain() {
    let host = Host()
    host.refuse = true
    host.publisher.tick()
    #expect(host.sent.isEmpty)
    host.refuse = false
    host.publisher.tick()
    #expect(host.positions.count == 1, "the position goes on the next tick")
    for _ in 0..<2 { host.publisher.tick() }
    #expect(host.shapes.count == 1, "the shape on the next shape tick")
  }

  @Test func anImageTooBigForTwiceTheScaleIsSentAtOnce() throws {
    let host = Host()
    host.image = Host.cursor(width: 200, height: 200)
    host.publisher.tick()
    let drawn = try #require(host.shapes.first?.shape())
    #expect(drawn.width == 200, "400 px at 2× is past the 256-px limit")
  }
}
