public struct ScreenSharingFrameRecord: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let sourceTimestampNs: Int64
  public let keyFrame: Bool
  public let sameClock: Bool
  public let host: ScreenSharingHostTimestamps?
  public let viewer: ScreenSharingViewerTimestamps
  public let stagesUs: ScreenSharingFrameStages
  public let stageSumUs: Int64?
  public let captureToPresentUs: Int64?

  package init(
    sequence: UInt64, decoded: ScreenSharingDecodedFrameTiming, presentation: ScreenSharingFramePresentation,
    estimate: ScreenSharingOnGlassEstimate, transport: ScreenSharingTransportEstimate, localClock: UInt64
  ) {
    self.sequence = sequence
    sourceTimestampNs = decoded.sourceTimestampNs
    keyFrame = decoded.isKeyFrame
    sameClock = localClock != 0 && decoded.host?.clock == localClock
    host = decoded.host.map { ScreenSharingHostTimestamps(sourceTimestampNs: decoded.sourceTimestampNs, timing: $0) }
    viewer = ScreenSharingViewerTimestamps(decoded: decoded, presentation: presentation, estimate: estimate)
    stagesUs = Self.stages(decoded: decoded, viewer: viewer, transport: transport)
    stageSumUs = stagesUs.sum
    captureToPresentUs = Self.captureToPresentUs(sourceTimestampNs, viewer: viewer, sameClock: sameClock)
  }

  private static func stages(
    decoded: ScreenSharingDecodedFrameTiming, viewer: ScreenSharingViewerTimestamps,
    transport: ScreenSharingTransportEstimate
  ) -> ScreenSharingFrameStages {
    var stages = ScreenSharingFrameStages()
    stages.capture = decoded.host?.captureUs
    stages.hostQueue = decoded.host?.hostQueueUs
    stages.encode = decoded.host?.encodeUs
    stages.network = transport.networkUs
    stages.jitterBuffer = transport.jitterBufferUs
    stages.decode = microseconds(from: viewer.decodeInputNs, to: viewer.decodeOutputNs)
    stages.delivery = viewer.mailboxPutNs.map { microseconds(from: viewer.decodeOutputNs, to: $0) }
    stages.renderQueue = viewer.mailboxPutNs.map { microseconds(from: $0, to: viewer.renderCommitNs) }
    stages.present = viewer.onGlassNs.map { microseconds(from: viewer.renderCommitNs, to: $0) }
    return stages
  }

  private static func captureToPresentUs(
    _ sourceTimestampNs: Int64, viewer: ScreenSharingViewerTimestamps, sameClock: Bool
  ) -> Int64? {
    guard sameClock, let onGlassNs = viewer.onGlassNs else { return nil }
    return microseconds(from: sourceTimestampNs, to: onGlassNs)
  }

  private static func microseconds(from start: Int64, to end: Int64) -> Int64 { (end - start) / 1000 }
}
