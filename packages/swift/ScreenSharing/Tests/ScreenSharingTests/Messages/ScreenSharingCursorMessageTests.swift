import AppKit
import CodevisorTestSupport
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

  /// What the scripted system reports. The publisher reads it on its own queue.
  final class System: @unchecked Sendable {
    private let lock = NSLock()
    private var _pointer = ScreenSharingCursorPublisher.Pointer(
      location: CGPoint(x: 150, y: 125), image: Host.cursor(width: 10, height: 16), hotSpot: CGPoint(x: 2, y: 3))
    private var _scale: CGFloat = 2
    private var _scaleReads = 0

    var pointer: ScreenSharingCursorPublisher.Pointer {
      get { lock.withLock { _pointer } }
      set { lock.withLock { _pointer = newValue } }
    }
    var scale: CGFloat {
      get { lock.withLock { _scale } }
      set { lock.withLock { _scale = newValue } }
    }
    var scaleReads: Int { lock.withLock { _scaleReads } }
    func readScale() -> CGFloat {
      lock.withLock {
        _scaleReads += 1
        return _scale
      }
    }
  }

  @MainActor final class Host {
    let system = System()
    let metrics = ScreenSharingMetrics()
    let clock = TestClock()
    var sent: [ScreenSharingCursorMessage] = []
    var refuse = false
    /// A 1000 × 500-point display at (100, 100), 2×.
    lazy var publisher = ScreenSharingCursorPublisher(
      bounds: { CGRect(x: 100, y: 100, width: 1000, height: 500) }, scale: { [system] in system.readScale() },
      pointer: { [system] in system.pointer }, metrics: metrics, clock: clock,
      send: { [unowned self] message in
        guard !refuse else { return false }
        sent.append(message)
        return true
      })

    var location: CGPoint {
      get { system.pointer.location }
      set { system.pointer.location = newValue }
    }
    var image: NSImage {
      get { system.pointer.image }
      set { system.pointer.image = newValue }
    }
    var hotSpot: CGPoint {
      get { system.pointer.hotSpot }
      set { system.pointer.hotSpot = newValue }
    }
    /// Shapes drawn and PNG-encoded, as the host's diagnostics count them.
    var drawn: Int { metrics.counter("cursorShapesDrawn") }

    func tick(_ count: Int = 1) async {
      for _ in 0..<count { await publisher.tick() }
    }

    /// Drawn on whatever thread asks for it: the publisher draws on its own queue.
    nonisolated static func cursor(width: CGFloat, height: CGFloat, color: NSColor = .black) -> NSImage {
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

  @Test func theFirstTickSendsTheShapeThenThePosition() async throws {
    let host = Host()
    await host.tick()
    let shape = try #require(host.shapes.first)
    #expect(host.sent.count == 2)
    #expect(host.positions == [ScreenSharingPointer(x: 0.05, y: 0.05)])
    // 2×: 20 × 32 pixels with the hotspot doubled, sized as a share of the display.
    let drawn = try #require(shape.shape())
    #expect(drawn.width == 20 && drawn.height == 32)
    #expect(shape.hotspotX == 4 && shape.hotspotY == 6)
    #expect(shape.width == 0.01 && shape.height == 0.032)
  }

  @Test func onlyChangesAreSentAndOnlyANewLookIsDrawn() async {
    let host = Host()
    await host.tick()
    // The system hands out a new image every poll: one that looks the same is not drawn again.
    host.image = Host.cursor(width: 10, height: 16)
    await host.tick(2 * ScreenSharingCursorPublisher.shapeEvery)
    #expect(host.sent.count == 2, "nothing moved, nothing changed")
    #expect(host.drawn == 1)
    host.location = CGPoint(x: 600, y: 350)
    await host.tick()
    #expect(host.positions.last == ScreenSharingPointer(x: 0.5, y: 0.5))
    // Shapes are looked at every third tick: a change shows up within three.
    host.image = Host.cursor(width: 10, height: 16, color: .white)
    await host.tick(ScreenSharingCursorPublisher.shapeEvery)
    #expect(host.shapes.count == 2)
    host.hotSpot = CGPoint(x: 5, y: 5)
    await host.tick(ScreenSharingCursorPublisher.shapeEvery)
    #expect(host.shapes.last.map { [$0.hotspotX, $0.hotspotY] } == [10, 10])
    #expect(host.drawn == 3)
  }

  @Test func aPointerOnAnotherDisplayIsSentAsAbsentOnce() async {
    let host = Host()
    await host.tick()
    host.location = CGPoint(x: 50, y: 50)
    await host.tick(2)
    #expect(host.positions == [ScreenSharingPointer(x: 0.05, y: 0.05), nil])
    #expect(
      ScreenSharingCursorPublisher.position(
        CGPoint(x: 1100, y: 600), in: CGRect(x: 100, y: 100, width: 1000, height: 500))
        == ScreenSharingPointer(x: 1, y: 1))
  }

  @Test func whatTheChannelRefusedIsSentAgain() async {
    let host = Host()
    host.refuse = true
    await host.tick()
    #expect(host.sent.isEmpty)
    host.refuse = false
    await host.tick()
    #expect(host.positions.count == 1, "the position goes on the next tick")
    await host.tick(2)
    #expect(host.shapes.count == 1, "the shape on the next shape tick")
    #expect(host.drawn == 1, "without drawing it again")
  }

  @Test func anImageTooBigForTwiceTheScaleIsSentAtOnce() async throws {
    let host = Host()
    host.image = Host.cursor(width: 200, height: 200)
    await host.tick()
    let drawn = try #require(host.shapes.first?.shape())
    #expect(drawn.width == 200, "400 px at 2× is past the 256-px limit")
  }

  @Test func theDisplayScaleIsReadOnceASecondAndANewOneRedrawsTheShape() async throws {
    let host = Host()
    await host.tick()
    host.system.scale = 1
    await host.tick(ScreenSharingCursorPublisher.scaleEvery - 1)
    #expect(host.system.scaleReads == 1)
    #expect(host.shapes.count == 1)
    await host.tick(ScreenSharingCursorPublisher.shapeEvery)
    #expect(host.system.scaleReads == 2)
    let redrawn = try #require(host.shapes.dropFirst().first?.shape())
    #expect(redrawn.width == 10 && redrawn.height == 16, "1×")
  }

  @Test func startedItPollsOnTheClockUntilStopped() async {
    let host = Host()
    let interval = ScreenSharingCursorPublisher.positionInterval
    host.publisher.start()
    await host.clock.waitForSleep(interval)
    #expect(host.shapes.count == 1 && host.positions == [ScreenSharingPointer(x: 0.05, y: 0.05)])
    host.location = CGPoint(x: 600, y: 350)
    host.clock.advance(by: interval)
    await host.clock.waitForSleep(interval, count: 2)
    #expect(host.positions.last == ScreenSharingPointer(x: 0.5, y: 0.5))

    host.publisher.stop()
    // The poll's sleep is cancelled, so nothing is left to wake it.
    while true {
      let revision = host.clock.changed.value
      if host.clock.pendingCount == 0 { break }
      await host.clock.changed.wait(for: revision + 1)
    }
    host.location = CGPoint(x: 1100, y: 600)
    host.clock.advance(by: interval)
    #expect(host.clock.requestCount(interval) == 2)
    #expect(host.positions.count == 2)
  }
}
