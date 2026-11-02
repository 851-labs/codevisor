import CodevisorTestSupport
import ScreenSharing
import Synchronization

final class DecodedFrames: Sendable {
  let arrivals = TestSignal()
  private let received = Mutex<[ScreenSharingVideoFrame]>([])

  init(_ mailbox: ScreenSharingFrameMailbox) {
    mailbox.onFrameAvailable { [self] in
      guard let frame = mailbox.take() else { return }

      received.withLock { $0.append(frame) }
      arrivals.signal()
    }
  }

  var frames: [ScreenSharingVideoFrame] { received.withLock { $0 } }
  var sourceTimestamps: [Int64] { frames.map { $0.sourceTimestampNs ?? -1 } }
}
