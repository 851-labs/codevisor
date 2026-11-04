import CoreVideo
import Testing

@testable import ScreenSharing

struct ScreenSharingFrameMailboxTests {
  private func frame(_ id: UInt32, first: Bool = false) throws -> ScreenSharingVideoFrame {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    return .init(
      pixelBuffer: try #require(pixel), timestampNs: Int64(id), rtpTimestamp: id, presentsBeforeNext: first)
  }

  @Test func aFrameThatPresentsFirstIsTakenBeforeTheNewestOfTheFramesQueuedBehindIt() throws {
    let mailbox = ScreenSharingFrameMailbox()
    mailbox.put(try frame(1, first: true))
    mailbox.put(try frame(2))
    mailbox.put(try frame(3))

    #expect(mailbox.take()?.rtpTimestamp == 1)
    #expect(mailbox.take()?.rtpTimestamp == 3)
    #expect(mailbox.take() == nil)
    #expect(mailbox.droppedFrames == 1)
  }

  @Test func aNewerFrameThatPresentsFirstReplacesTheHeldOneAndWhatQueuedBehindIt() throws {
    let mailbox = ScreenSharingFrameMailbox()
    mailbox.put(try frame(1, first: true))
    mailbox.put(try frame(2))
    mailbox.put(try frame(3, first: true))

    #expect(mailbox.take()?.rtpTimestamp == 3)
    #expect(mailbox.take() == nil)
    #expect(mailbox.droppedFrames == 2)
    #expect(mailbox.supersededPresentFirstFrames == 1)
  }

  @Test func ordinaryFramesStillReplaceEachOther() throws {
    let mailbox = ScreenSharingFrameMailbox()
    mailbox.put(try frame(1))
    mailbox.put(try frame(2, first: true))
    mailbox.put(try frame(3))

    #expect(mailbox.take()?.rtpTimestamp == 2)
    #expect(mailbox.take()?.rtpTimestamp == 3)
    #expect(mailbox.droppedFrames == 1)
  }
}
