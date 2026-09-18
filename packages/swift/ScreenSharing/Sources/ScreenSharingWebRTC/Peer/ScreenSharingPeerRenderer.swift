import Foundation
import QuartzCore
@preconcurrency import WebRTC
import ScreenSharing

final class ScreenSharingPeerRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  let mailbox: ScreenSharingFrameMailbox
  let metrics: ScreenSharingMetrics
  private let audit: ScreenSharingFrameDeliveryAudit?
  init(mailbox: ScreenSharingFrameMailbox, metrics: ScreenSharingMetrics, audit: ScreenSharingFrameDeliveryAudit? = nil)
  {
    self.mailbox = mailbox; self.metrics = metrics; self.audit = audit
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
      // Audit identity crosses WebRTC's native-buffer bridge as the buffer attachment (nil when the audit is off).
      var identity: ScreenSharingFrameDeliveryAudit.Identity?
      if let audit {
        identity = ScreenSharingFrameDeliveryAudit.readIdentity(from: native.pixelBuffer)
        audit.record(.rtcRendererCallback, identity, rtpTimestamp: UInt32(bitPattern: frame.timeStamp))
      }
      let replaced = mailbox.put(
        ScreenSharingVideoFrame(
          pixelBuffer: native.pixelBuffer, timestampNs: frame.timeStampNs,
          rtpTimestamp: UInt32(bitPattern: frame.timeStamp), receivedAtSeconds: CACurrentMediaTime(),
          sourceTimestampNs: ScreenSharingFrameIdentity.sourceTimestampNs(of: native.pixelBuffer),
          deliveryAuditIdentity: identity))
      if let audit, let replaced {
        audit.record(.mailboxReplaced, replaced.deliveryAuditIdentity, rtpTimestamp: replaced.rtpTimestamp)
      }
    }
  }
}

/// Delegate callbacks originate on WebRTC threads. Hooks are installed before
/// negotiation and only hop to the main actor; their storage is then immutable.
