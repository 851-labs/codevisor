import CoreVideo
import ScreenSharing

final class ScreenSharingV2DecodeContext: @unchecked Sendable {
  let frame: ScreenSharingReceivedFrame
  let meta: ScreenSharingV2FrameMeta
  let receivedNs: Int64
  let submittedNs: Int64
  private let output: @Sendable (ScreenSharingV2DecodeResult) -> Void

  init(
    frame: ScreenSharingReceivedFrame, meta: ScreenSharingV2FrameMeta, receivedNs: Int64, submittedNs: Int64,
    output: @escaping @Sendable (ScreenSharingV2DecodeResult) -> Void
  ) {
    self.frame = frame
    self.meta = meta
    self.receivedNs = receivedNs
    self.submittedNs = submittedNs
    self.output = output
  }

  func deliver(status: OSStatus, image: CVImageBuffer?) {
    guard status == noErr, let image else { return output(.failed(self, status)) }

    output(.decoded(self, image, decodedNs: ScreenSharingMetrics.nowNs))
  }
}
