import CoreMedia
import ScreenCaptureKit

public enum BenchCapturedFrame {
  public static func observation(
    of sampleBuffer: CMSampleBuffer, layout: BenchBarcodeLayout, callbackNs: Int64, continuousMinusAbsoluteNs: Int64
  ) throws -> BenchObservation? {
    guard isComplete(sampleBuffer), let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

    let reading = try BenchBarcode.read(image, layout: layout)
    let ptsNs = absolutePresentationNs(of: sampleBuffer) + continuousMinusAbsoluteNs
    return BenchObservation(ptsNs: ptsNs, callbackNs: callbackNs, reading: reading)
  }

  private static let nanosecondsPerSecond: Int32 = 1_000_000_000

  private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
    guard let info = (attachments as? [[SCStreamFrameInfo: Any]])?.first else { return false }
    guard let status = info[.status] as? Int else { return false }

    return SCFrameStatus(rawValue: status) == .complete
  }

  private static func absolutePresentationNs(of sampleBuffer: CMSampleBuffer) -> Int64 {
    let hostTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    return CMTimeConvertScale(hostTime, timescale: nanosecondsPerSecond, method: .roundHalfAwayFromZero).value
  }
}
