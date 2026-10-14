import Foundation

public struct ScreenSharingCaptureRequestState: Sendable {
  public private(set) var overrideFramesPerSecond: Int?

  public init(overrideFramesPerSecond: Int?) { self.overrideFramesPerSecond = overrideFramesPerSecond }

  public func validated(
    video: ScreenSharingVideoConfiguration, override: Int?
  ) throws -> ScreenSharingCaptureIntervalRequest {
    try ScreenSharingCaptureIntervalRequest(
      videoFramesPerSecond: video.framesPerSecond, overrideFramesPerSecond: override)
  }

  public mutating func commit(
    override: Int?, request: ScreenSharingCaptureIntervalRequest, metrics: ScreenSharingMetrics
  ) {
    overrideFramesPerSecond = override
    metrics.label("captureRequestedMinimumFrameIntervalFPS", String(request.requestedFramesPerSecond))
    metrics.label(
      "captureRequestedFrameIntervalOverride", request.isOverride ? String(request.requestedFramesPerSecond) : "none")
  }
}
