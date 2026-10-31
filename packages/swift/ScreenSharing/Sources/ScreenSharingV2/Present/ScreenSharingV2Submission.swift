@preconcurrency import Metal
import QuartzCore
import ScreenSharing

struct ScreenSharingV2Submission: @unchecked Sendable {
  let buffer: any MTLCommandBuffer
  let drawable: any CAMetalDrawable
  let retained: AnyObject & Sendable

  func commit(_ frame: ScreenSharingVideoFrame, isNew: Bool, metrics: ScreenSharingMetrics) {
    let submittedAt = CACurrentMediaTime()
    buffer.addCompletedHandler { [retained] _ in withExtendedLifetime(retained) {} }
    drawable.addPresentedHandler { [self] presented in
      metrics.recordPresentation(
        isNewFrame: isNew, presentedAt: presented.presentedTime, submittedAt: submittedAt,
        receivedAt: frame.receivedAtSeconds, sourceTimestampNs: frame.sourceTimestampNs, gpuCompletedAt: gpuEndTime)
    }
    buffer.present(drawable)
    buffer.commit()
  }

  private var gpuEndTime: Double? {
    buffer.gpuEndTime > 0 ? buffer.gpuEndTime : nil
  }
}
