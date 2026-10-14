import CoreVideo
import Dispatch
import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingBufferTests {
  @Test func slowConsumerReceivesNewestFrameAndReleasesQueuedFrame() throws {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    let mailbox = ScreenSharingFrameMailbox()
    for timestamp in 1...100 {
      mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: Int64(timestamp)))
    }
    #expect(mailbox.droppedFrames == 99)
    #expect(mailbox.take()?.timestampNs == 100)
    #expect(mailbox.take() == nil)
    mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: 101))
    mailbox.clear()
    #expect(mailbox.take() == nil)
    #expect(mailbox.droppedFrames == 99)
  }

  @Test func concurrentMailboxProducersAccountForEveryFrame() throws {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    let mailbox = ScreenSharingFrameMailbox()
    let frames = (0..<512).map { ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: Int64($0)) }
    DispatchQueue.concurrentPerform(iterations: 8) { producer in
      for index in 0..<64 {
        mailbox.put(frames[producer * 64 + index])
      }
    }
    let held = try #require(mailbox.take())
    #expect((0..<512).contains(held.timestampNs))
    #expect(mailbox.droppedFrames == 511)
    #expect(mailbox.take() == nil)
  }

  @Test func rendererNotificationsAreBoundedUntilMailboxIsDrained() throws {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    let mailbox = ScreenSharingFrameMailbox()
    let notifications = ScreenSharingMetrics()
    mailbox.onFrameAvailable { notifications.increment("available") }
    for timestamp in 1...100 {
      mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: Int64(timestamp)))
    }
    #expect(notifications.snapshot().counters["available"] == 1)
    #expect(mailbox.take()?.timestampNs == 100)
    mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: 101))
    #expect(notifications.snapshot().counters["available"] == 2)
    mailbox.onFrameAvailable(nil)
    mailbox.clear()
    mailbox.put(ScreenSharingVideoFrame(pixelBuffer: buffer, timestampNs: 102))
    #expect(notifications.snapshot().counters["available"] == 2)
    mailbox.onFrameAvailable { notifications.increment("available") }
    #expect(notifications.snapshot().counters["available"] == 3)
  }

  @Test(arguments: [0, 63, 1921, 3842])
  func rejectsUnsupportedWidths(_ width: Int) {
    #expect(throws: (any Error).self) { try ScreenSharingVideoConfiguration(width: width) }
  }
}
