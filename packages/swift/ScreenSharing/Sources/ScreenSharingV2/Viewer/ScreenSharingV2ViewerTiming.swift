import ScreenSharing

enum ScreenSharingV2ViewerTiming {
  static func composed(
    _ group: ScreenSharingV2UpdateAssembly.Group, decodedNs: Int64
  ) -> ScreenSharingDecodedFrameTiming? {
    guard !group.update.isRefinement, let critical = group.decoded.max(by: { hostEndNs($0) < hostEndNs($1) }) else {
      return nil
    }

    let meta = critical.meta
    let decodeInputNs = group.decoded.map(\.receivedNs).min() ?? critical.receivedNs
    let host = ScreenSharingHostFrameTiming(
      clock: meta.clock, captureUs: Int64(meta.captureUs), hostQueueUs: Int64(meta.admissionUs),
      encodeUs: Int64(meta.encodeUs), handOffUs: Int64(meta.handOffUs))
    return ScreenSharingDecodedFrameTiming(
      sourceTimestampNs: meta.sourceTimestampNs, host: host, assembleUs: assembleUs(critical, until: decodeInputNs),
      decodeInputNs: decodeInputNs,
      decodeSubmitNs: group.decoded.map(\.submittedNs).min() ?? critical.submittedNs, decodedNs: decodedNs,
      isKeyFrame: group.decoded.contains { $0.frame.isKeyFrame })
  }

  private static func assembleUs(_ critical: ScreenSharingV2DecodeContext, until decodeInputNs: Int64) -> Int64 {
    let firstPacketNs = critical.receivedNs - Int64(clamping: critical.frame.assemblingUs) * 1000
    return max(0, decodeInputNs - firstPacketNs) / 1000
  }

  private static func hostEndNs(_ context: ScreenSharingV2DecodeContext) -> Int64 {
    let meta = context.meta
    return Int64(meta.captureUs) + Int64(meta.admissionUs) + Int64(meta.encodeUs) + Int64(meta.handOffUs)
  }
}
