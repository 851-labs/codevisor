import CoreVideo
import Foundation

package enum ScreenSharingFrameIdentity {
  private static let key = "com.codevisor.screen-sharing.source-timestamp-ns"

  package static func attach(sourceTimestampNs: Int64, to buffer: CVPixelBuffer) {
    CVBufferSetAttachment(buffer, key as CFString, sourceTimestampNs as CFNumber, .shouldNotPropagate)
  }

  package static func sourceTimestampNs(of buffer: CVPixelBuffer) -> Int64? {
    (CVBufferCopyAttachment(buffer, key as CFString, nil) as? NSNumber)?.int64Value
  }

  package static func required(of buffer: CVPixelBuffer, metrics: ScreenSharingMetrics) -> Int64? {
    guard let identity = sourceTimestampNs(of: buffer) else {
      metrics.increment("encoderInputWithoutIdentity")
      metrics.label("encoderError", "Encoder input carries no content identity.")
      return nil
    }
    return identity
  }
}
