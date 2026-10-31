import CodevisorTestSupport
import ScreenSharing
import Synchronization

final class DecodedFrames: Sendable {
  let arrivals = TestSignal()
  private let timestamps = Mutex<[Int64]>([])

  init(_ mailbox: ScreenSharingFrameMailbox) {
    mailbox.onFrameAvailable { [self] in
      guard let frame = mailbox.take() else { return }

      timestamps.withLock { $0.append(frame.sourceTimestampNs ?? -1) }
      arrivals.signal()
    }
  }

  var sourceTimestamps: [Int64] { timestamps.withLock { $0 } }
}
