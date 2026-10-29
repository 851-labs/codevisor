import Metal
import ScreenSharing

struct OffscreenSubmission: ScreenSharingRenderSubmission, @unchecked Sendable {
  let buffer: any MTLCommandBuffer

  func onCompleted(_ handler: @escaping @Sendable (Bool) -> Void) {
    buffer.addCompletedHandler { handler($0.status == .completed) }
  }

  func onPresented(_ handler: @escaping @Sendable (Double, Double?) -> Void) {
    buffer.addCompletedHandler { handler(0, $0.gpuEndTime > 0 ? $0.gpuEndTime : nil) }
  }

  func commit() {
    buffer.commit()
  }
}
