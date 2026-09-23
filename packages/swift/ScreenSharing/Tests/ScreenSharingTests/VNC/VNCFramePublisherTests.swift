import CoreVideo
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

/// Copy only what changed (851-2319): every published frame equals the
/// framebuffer, and a small update copies a small number of bytes.
struct VNCFramePublisherTests {
  /// The rectangles a scene frame changed; nil when it resized.
  static func changed(_ rectangles: [RFBLoopbackServer.Rectangle]) -> [RFBRectangle]? {
    var out: [RFBRectangle] = []
    for rectangle in rectangles {
      switch rectangle {
      case .raw(let r), .zrle(let r), .encoded(let r), .copy(let r, _, _), .moved(let r, _, _): out.append(r)
      case .desktopSize, .extendedDesktopSize: return nil
      case .cursor, .pointer: break
      }
    }
    return out
  }

  static func pixels(_ frame: ScreenSharingVideoFrame, width: Int, height: Int) -> [UInt8] {
    let buffer = frame.pixelBuffer
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    var out: [UInt8] = []
    for y in 0..<height {
      for x in 0..<width {
        let p = base + y * stride + x * 4
        out += [p[0], p[1], p[2]]
      }
    }
    return out
  }

  static func colour(_ framebuffer: RFBFramebuffer) -> [UInt8] {
    framebuffer.pixels.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }
  }

  @Test(arguments: RFBLoopbackScene.Kind.allCases.filter { $0 != .idle })
  func everyPublishedFrameEqualsTheFramebuffer(kind: RFBLoopbackScene.Kind) throws {
    let framebuffer = try RFBFramebuffer(width: 96, height: 64)
    let publisher = VNCFramePublisher()
    let mailbox = ScreenSharingFrameMailbox()
    let metrics = ScreenSharingMetrics()
    var scene = RFBLoopbackScene(kind: kind, seed: 4)
    publisher.publish(framebuffer, changed: nil, to: mailbox, metrics: metrics)
    _ = mailbox.take()
    var held: [ScreenSharingVideoFrame] = []
    for frame in 0..<24 {
      let changed = Self.changed(try scene.next(on: framebuffer))
      publisher.publish(framebuffer, changed: changed, to: mailbox, metrics: metrics)
      let published = try #require(mailbox.take())
      #expect(
        Self.pixels(published, width: framebuffer.width, height: framebuffer.height) == Self.colour(framebuffer),
        "frame \(frame) of \(kind)")
      // Hold some frames for a while, as a renderer does, so buffers come back with different backlogs.
      held.append(published)
      if held.count > frame % 3 { held.removeFirst() }
    }
  }

  @Test func aSmallUpdateCopiesAboutItsOwnArea() throws {
    let framebuffer = try RFBFramebuffer(width: 1280, height: 800)
    let publisher = VNCFramePublisher()
    let mailbox = ScreenSharingFrameMailbox()
    let metrics = ScreenSharingMetrics()
    var scene = RFBLoopbackScene(kind: .typing, seed: 1)
    publisher.publish(framebuffer, changed: nil, to: mailbox, metrics: metrics)
    _ = mailbox.take()
    // Warm the pool: its buffers are new the first time round and copied whole.
    for _ in 0..<6 {
      publisher.publish(
        framebuffer, changed: Self.changed(try scene.next(on: framebuffer)), to: mailbox, metrics: metrics)
      _ = mailbox.take()
    }
    let before = metrics.snapshot().counters["vncBytesCopied", default: 0]
    let updates = 20
    for _ in 0..<updates {
      publisher.publish(
        framebuffer, changed: Self.changed(try scene.next(on: framebuffer)), to: mailbox, metrics: metrics)
      _ = mailbox.take()
    }
    let perUpdate = (metrics.snapshot().counters["vncBytesCopied", default: 0] - before) / updates
    // A glyph is 8 × 12; a buffer may also owe the glyphs of the updates it missed.
    let glyph = 8 * 12 * 4
    #expect(perUpdate <= glyph * VNCFramePublisher.maximumTrackedBuffers, "\(perUpdate) bytes per update")
    #expect(perUpdate * 1000 < 1280 * 800 * 4, "far below a full 4 MB frame")
  }

  @Test func aResizeOrUnknownChangeCopiesTheWholeFrame() throws {
    let framebuffer = try RFBFramebuffer(width: 32, height: 16)
    let publisher = VNCFramePublisher()
    let mailbox = ScreenSharingFrameMailbox()
    let metrics = ScreenSharingMetrics()
    publisher.publish(framebuffer, changed: nil, to: mailbox, metrics: metrics)
    _ = mailbox.take()
    publisher.publish(framebuffer, changed: nil, to: mailbox, metrics: metrics)
    _ = mailbox.take()
    #expect(metrics.snapshot().counters["vncBytesCopied"] == 2 * 32 * 16 * 4)
    try framebuffer.resize(width: 20, height: 10)
    publisher.publish(
      framebuffer, changed: [RFBRectangle(x: 0, y: 0, width: 1, height: 1)], to: mailbox, metrics: metrics)
    #expect(metrics.snapshot().counters["vncBytesCopied"] == 2 * 32 * 16 * 4 + 20 * 10 * 4, "new size: new buffers")
  }
}

extension VNCFramePublisherTests {
  /// Found by the first A/B run: a reused buffer's backlog repeated this
  /// update's full-frame rectangle, so photo and scroll copied 8 MB, not 4.
  @Test(arguments: [RFBLoopbackScene.Kind.photo, .scroll])
  func fullFrameUpdatesCopyTheFrameOnce(kind: RFBLoopbackScene.Kind) throws {
    let framebuffer = try RFBFramebuffer(width: 320, height: 200)
    let publisher = VNCFramePublisher()
    let mailbox = ScreenSharingFrameMailbox()
    let metrics = ScreenSharingMetrics()
    var scene = RFBLoopbackScene(kind: kind, seed: 6)
    for _ in 0..<10 {
      let before = metrics.snapshot().counters["vncBytesCopied", default: 0]
      publisher.publish(
        framebuffer, changed: Self.changed(try scene.next(on: framebuffer)), to: mailbox, metrics: metrics)
      _ = mailbox.take()
      #expect(metrics.snapshot().counters["vncBytesCopied", default: 0] - before <= 320 * 200 * 4)
    }
  }

  @Test func coalescingDropsDuplicatesAndCollapsesToTheFrame() {
    let full = RFBRectangle(x: 0, y: 0, width: 10, height: 10)
    let small = RFBRectangle(x: 1, y: 1, width: 2, height: 2)
    #expect(VNCFramePublisher.coalesce([small, small], full: full) == [small])
    #expect(VNCFramePublisher.coalesce([full, full], full: full) == [full])
    #expect(
      VNCFramePublisher.coalesce(
        [RFBRectangle(x: 0, y: 0, width: 10, height: 6), RFBRectangle(x: 0, y: 5, width: 10, height: 5)], full: full)
        == [full])
  }
}
