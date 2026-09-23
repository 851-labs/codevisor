import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import ScreenSharing
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use live preview")
struct ComputerUseLivePreviewTests {
  // MARK: Stream settings

  @Test("Watching raises the frame rate without changing the preview size")
  func previewSettingsFollowViewers() {
    let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let idle = computerUseNativePreviewSettings(windowFrame: frame, pointPixelScale: 2, viewerCount: 0)
    let watched = computerUseNativePreviewSettings(windowFrame: frame, pointPixelScale: 2, viewerCount: 2)

    #expect(idle.size == CGSize(width: 960, height: 640))
    #expect(watched.size == idle.size)
    #expect(idle.framesPerSecond == 5)
    #expect(watched.framesPerSecond == 15)
    // A renderer pins up to three buffers; the pool must exceed that.
    #expect(ComputerUseNativePreviewMetrics.queueDepth > 3)
  }

  // MARK: Frame publishing

  @Test("Fans complete frames out to every sink and drops idle callbacks")
  func publisherFanOut() throws {
    let publisher = ComputerUseFramePublisher()
    let first = RecordingSink()
    let second = RecordingSink()
    publisher.setSinks([UUID(): first, UUID(): second])

    publisher.publish(try sampleBuffer(status: .complete, seconds: 2))
    publisher.publish(try sampleBuffer(status: .idle, seconds: 3))
    publisher.publish(try sampleBuffer(status: .started, seconds: 4))

    #expect(first.timestamps == [2_000_000_000, 4_000_000_000])
    #expect(second.timestamps == first.timestamps)
  }

  @Test("A removed sink stops receiving frames")
  func publisherRemoval() throws {
    let publisher = ComputerUseFramePublisher()
    let kept = RecordingSink()
    let removed = RecordingSink()
    let keptID = UUID()
    publisher.setSinks([keptID: kept, UUID(): removed])
    publisher.publish(try sampleBuffer(status: .complete, seconds: 1))
    publisher.setSinks([keptID: kept])
    publisher.publish(try sampleBuffer(status: .complete, seconds: 2))
    publisher.removeAll()
    publisher.publish(try sampleBuffer(status: .complete, seconds: 3))

    #expect(kept.timestamps.count == 2)
    #expect(removed.timestamps.count == 1)
    #expect(!publisher.hasSinks)
  }

  @Test("A mailbox sink keeps only the newest frame")
  func mailboxSink() throws {
    let mailbox = ScreenSharingFrameMailbox()
    let sink = ComputerUseMailboxSink(mailbox: mailbox)
    let publisher = ComputerUseFramePublisher()
    publisher.setSinks([UUID(): sink])
    publisher.publish(try sampleBuffer(status: .complete, seconds: 1))
    publisher.publish(try sampleBuffer(status: .complete, seconds: 2))

    #expect(mailbox.take()?.timestampNs == 2_000_000_000)
    #expect(mailbox.droppedFrames == 1)
  }

  // MARK: Ledger

  @Test("Tracks a session through activity, idle, window switch and stop")
  func ledgerTransitions() {
    var ledger = ComputerUseLivePreviewLedger()
    let frame = CGRect(x: 100, y: 100, width: 400, height: 200)
    ledger.apply(activated("ABC", window: 7, frame: frame))
    #expect(ledger.activities["abc"]?.state == .active)
    #expect(ledger.activities["abc"]?.bridgeSessionID == "ABC")

    ledger.apply(.cursorMoved(sessionID: "abc", point: CGPoint(x: 300, y: 150)))
    #expect(ledger.activities["abc"]?.cursor == CGPoint(x: 0.5, y: 0.25))

    ledger.apply(.idled(sessionID: "ABC"))
    #expect(ledger.activities["abc"]?.state == .idle)
    // Idle sessions don't track the cursor.
    ledger.apply(.cursorMoved(sessionID: "abc", point: CGPoint(x: 100, y: 100)))
    #expect(ledger.activities["abc"]?.cursor == CGPoint(x: 0.5, y: 0.25))

    ledger.apply(activated("ABC", window: 7, frame: frame))
    #expect(ledger.activities["abc"]?.state == .active)
    #expect(ledger.activities["abc"]?.cursor == CGPoint(x: 0.5, y: 0.25))

    // A new window drops a cursor position that belonged to the old one.
    ledger.apply(activated("ABC", window: 8, frame: frame))
    #expect(ledger.activities["abc"]?.windowID == 8)
    #expect(ledger.activities["abc"]?.cursor == nil)

    // A stop for another pid leaves the session alone.
    ledger.apply(.stopped(sessionID: "abc", pid: 99))
    #expect(ledger.activities["abc"]?.state == .active)
    ledger.apply(.stopped(sessionID: "abc", pid: 42))
    #expect(ledger.activities["abc"]?.state == .stopped)

    ledger.apply(.removeAll)
    #expect(ledger.activities.isEmpty)
  }

  @Test("Follows the controlled window when it moves or resizes between tool calls")
  func ledgerFollowsWindowFrame() {
    var ledger = ComputerUseLivePreviewLedger()
    let frame = CGRect(x: 100, y: 100, width: 400, height: 200)
    ledger.apply(activated("abc", window: 7, frame: frame))
    ledger.apply(.cursorMoved(sessionID: "abc", point: CGPoint(x: 300, y: 150)))

    // Another window's bounds never apply.
    ledger.apply(.windowFrameChanged(sessionID: "abc", windowID: 8, frame: .zero))
    #expect(ledger.activities["abc"]?.windowFrame == frame)
    #expect(ledger.activities["abc"]?.cursor != nil)

    // An unchanged frame is a no-op, so observers are not woken 4 times a second.
    let unchanged = ledger
    ledger.apply(.windowFrameChanged(sessionID: "ABC", windowID: 7, frame: frame))
    #expect(ledger == unchanged)

    let resized = CGRect(x: 50, y: 80, width: 600, height: 500)
    ledger.apply(.windowFrameChanged(sessionID: "ABC", windowID: 7, frame: resized))
    #expect(ledger.activities["abc"]?.windowFrame == resized)
    // The old normalized cursor no longer lines up with the new frame.
    #expect(ledger.activities["abc"]?.cursor == nil)
  }

  @Test("Reads a window's bounds from the window server list")
  func windowBounds() {
    let info: [[String: Any]] = [
      [
        kCGWindowNumber as String: NSNumber(value: 3),
        kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 3, height: 4).dictionaryRepresentation,
      ],
      [
        kCGWindowNumber as String: NSNumber(value: 7),
        kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 640, height: 480).dictionaryRepresentation,
      ],
    ]
    #expect(computerUseWindowBounds(windowID: 7, windowInfo: info) == CGRect(x: 10, y: 20, width: 640, height: 480))
    #expect(computerUseWindowBounds(windowID: 9, windowInfo: info) == nil)
  }

  @Test("App termination stops every session controlling it")
  func ledgerTermination() {
    var ledger = ComputerUseLivePreviewLedger()
    ledger.apply(activated("one", window: 1, frame: .zero))
    ledger.apply(activated("two", window: 1, frame: .zero))
    ledger.apply(activated("three", window: 2, frame: .zero, pid: 7))
    ledger.apply(.terminated(pid: 42))

    #expect(ledger.activities["one"]?.state == .stopped)
    #expect(ledger.activities["two"]?.state == .stopped)
    #expect(ledger.activities["three"]?.state == .active)
  }

  @Test("Normalizes the cursor only inside the window")
  func normalizedCursor() {
    let frame = CGRect(x: 10, y: 20, width: 100, height: 50)
    #expect(computerUseNormalizedCursor(point: CGPoint(x: 10, y: 20), in: frame) == .zero)
    #expect(computerUseNormalizedCursor(point: CGPoint(x: 110, y: 70), in: frame) == CGPoint(x: 1, y: 1))
    #expect(computerUseNormalizedCursor(point: CGPoint(x: 5, y: 30), in: frame) == nil)
    #expect(computerUseNormalizedCursor(point: .zero, in: .zero) == nil)
  }

  // MARK: Idle release

  @Test("A watched session is never released as idle")
  func pinnedSessionsStayAttached() {
    let now = Date()
    let lastActivity = [
      "watched": now.addingTimeInterval(-3_600),
      "abandoned": now.addingTimeInterval(-3_600),
    ]
    let idle = computerUseIdleSessions(lastActivity: lastActivity, now: now, pinned: ["watched"])
    #expect(idle == ["abandoned"])
  }

  // MARK: Geometry

  @Test("Aspect-fits the frame into the card")
  func previewSize() {
    #expect(
      computerUseLivePreviewSize(frameSize: CGSize(width: 960, height: 640), maxWidth: 320, maxHeight: 400)
        == CGSize(width: 320, height: 213))
    #expect(
      computerUseLivePreviewSize(frameSize: CGSize(width: 400, height: 1000), maxWidth: 320, maxHeight: 400)
        == CGSize(width: 160, height: 400))
    #expect(
      computerUseLivePreviewSize(frameSize: .zero, maxWidth: 320, maxHeight: 400)
        == CGSize(width: 320, height: 200))
  }

  // MARK: Fixtures

  private func activated(
    _ sessionID: String,
    window: CGWindowID,
    frame: CGRect,
    pid: pid_t = 42
  ) -> ComputerUseLivePreviewLedger.Event {
    .activated(
      sessionID: sessionID, appName: "TextEdit", pid: pid, windowID: window,
      windowFrame: frame, colorIndex: 0)
  }
}

final class RecordingSink: ComputerUseFrameSink, @unchecked Sendable {
  private let lock = NSLock()
  private var received: [Int64] = []
  private var prepared: [CGSize] = []

  var timestamps: [Int64] { lock.withLock { received } }
  var preparedSizes: [CGSize] { lock.withLock { prepared } }

  @MainActor func prepare(size: CGSize) { lock.withLock { prepared.append(size) } }
  func push(_ frame: ScreenSharingVideoFrame) { lock.withLock { received.append(frame.timestampNs) } }
}

struct SampleBufferFixtureError: Error {}

/// A BGRA sample buffer carrying ScreenCaptureKit's frame-status attachment.
func sampleBuffer(status: SCFrameStatus, seconds: Int64) throws -> CMSampleBuffer {
  var pixelBuffer: CVPixelBuffer?
  CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
  guard let pixelBuffer else { throw SampleBufferFixtureError() }
  var format: CMVideoFormatDescription?
  CMVideoFormatDescriptionCreateForImageBuffer(
    allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
  guard let format else { throw SampleBufferFixtureError() }
  var timing = CMSampleTimingInfo(
    duration: .invalid,
    presentationTimeStamp: CMTime(value: seconds, timescale: 1),
    decodeTimeStamp: .invalid
  )
  var buffer: CMSampleBuffer?
  CMSampleBufferCreateReadyWithImageBuffer(
    allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
    sampleTiming: &timing, sampleBufferOut: &buffer)
  guard let buffer,
    let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
    CFArrayGetCount(attachments) > 0
  else { throw SampleBufferFixtureError() }
  let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
  CFDictionarySetValue(
    dictionary,
    Unmanaged.passUnretained(SCStreamFrameInfo.status.rawValue as CFString).toOpaque(),
    Unmanaged.passUnretained(NSNumber(value: status.rawValue)).toOpaque()
  )
  return buffer
}
