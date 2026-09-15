import CoreVideo
import Foundation

/// Content identity travels with the pixel buffer. WebRTC's native source
/// truncates the submitted timestamp to microseconds and translates it through
/// its timestamp aligner before the frame reaches the encoder, so a timestamp
/// alone cannot identify a frame across that boundary. The identity is the
/// capture presentation timestamp; a refresh resubmits the same buffer and
/// therefore the same content identity, and a new capture into a recycled
/// buffer sets a new one before submission.
package enum ScreenSharingFrameIdentity {
  private static let key = "com.codevisor.screen-sharing.source-timestamp-ns"

  package static func attach(sourceTimestampNs: Int64, to buffer: CVPixelBuffer) {
    CVBufferSetAttachment(buffer, key as CFString, sourceTimestampNs as CFNumber, .shouldNotPropagate)
  }

  package static func sourceTimestampNs(of buffer: CVPixelBuffer) -> Int64? {
    (CVBufferCopyAttachment(buffer, key as CFString, nil) as? NSNumber)?.int64Value
  }

  /// The transport path requires identity. A missing attachment means the
  /// bridge no longer forwards the native buffer; substituting WebRTC's
  /// translated timestamp would mix clocks, so the frame is refused and the
  /// established encoder failure lifecycle ends the session.
  package static func required(of buffer: CVPixelBuffer, metrics: ScreenSharingMetrics) -> Int64? {
    guard let identity = sourceTimestampNs(of: buffer) else {
      metrics.increment("encoderInputWithoutIdentity")
      metrics.label("encoderError", "Encoder input carries no content identity.")
      return nil
    }
    return identity
  }
}
