import Foundation
import QuartzCore
@preconcurrency import WebRTC
import ScreenSharing

final class ScreenSharingPeerRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  let mailbox: ScreenSharingFrameMailbox
  let metrics: ScreenSharingMetrics
  init(mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics) {
    self.mailbox = mailbox; self.metrics = metrics
  }
  func setSize(_ size: CGSize) {}
  func stop() {
    lock.withLock {
      active = false; mailbox.clear()
    }
  }
  func renderFrame(_ frame: RTCVideoFrame?) {
    lock.withLock {
      guard active, let frame, let native = frame.buffer as? RTCCVPixelBuffer, frame.rotation == ._0 else { return }
      metrics.increment("receivedFrames")
      metrics.event("receiverCallbackInterval", atNanoseconds: ScreenSharingMetrics.nowNs)
      mailbox.put(
        ScreenSharingVideoFrame(
          pixelBuffer: native.pixelBuffer, timestampNs: frame.timeStampNs,
          rtpTimestamp: UInt32(bitPattern: frame.timeStamp), receivedAtSeconds: CACurrentMediaTime(),
          sourceTimestampNs: ScreenSharingFrameIdentity.sourceTimestampNs(of: native.pixelBuffer)))
    }
  }
}
