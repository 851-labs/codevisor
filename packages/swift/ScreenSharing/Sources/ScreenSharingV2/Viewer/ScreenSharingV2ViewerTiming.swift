import ScreenSharing

enum ScreenSharingV2ViewerTiming {
  static func decoded(_ context: ScreenSharingV2DecodeContext, decodedNs: Int64) -> ScreenSharingDecodedFrameTiming {
    let meta = context.meta
    let host = ScreenSharingHostFrameTiming(
      clock: meta.clock, captureUs: Int64(meta.captureUs), hostQueueUs: Int64(meta.admissionUs),
      encodeUs: Int64(meta.encodeUs))
    return ScreenSharingDecodedFrameTiming(
      sourceTimestampNs: meta.sourceTimestampNs, host: host, decodeInputNs: context.receivedNs,
      decodeSubmitNs: context.submittedNs, decodedNs: decodedNs, isKeyFrame: context.frame.isKeyFrame)
  }
}
