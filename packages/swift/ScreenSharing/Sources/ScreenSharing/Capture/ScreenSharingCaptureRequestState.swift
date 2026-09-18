import Foundation

/// The capture-interval REQUEST state of one running capture, separated from ScreenCaptureKit so the
/// validate → apply → commit ordering is testable without a stream.
///
/// The rule it enforces: nothing about the stored request or its telemetry changes until the stream update has
/// actually succeeded in the same generation. A validation failure, a failed update or a stale generation leaves the
/// previous request and labels exactly as they were — the telemetry never describes a request that is not in force.
public struct ScreenSharingCaptureRequestState: Sendable {
  /// The override currently in force; nil means the request equals the video rate.
  public private(set) var overrideFramesPerSecond: Int?

  public init(overrideFramesPerSecond: Int?) { self.overrideFramesPerSecond = overrideFramesPerSecond }

  /// Validates a candidate request WITHOUT changing any state. Throws exactly as the single validated path does, so an
  /// override that was valid for the previous video rate but not for the new one fails here, before the stream call.
  public func validated(
    video: ScreenSharingVideoConfiguration, override: Int?
  ) throws -> ScreenSharingCaptureIntervalRequest {
    try ScreenSharingCaptureIntervalRequest(
      videoFramesPerSecond: video.framesPerSecond, overrideFramesPerSecond: override)
  }

  /// Commits a request that HAS been applied, and only then publishes its telemetry. Call this after a successful
  /// stream update in the same generation, never before.
  public mutating func commit(
    override: Int?, request: ScreenSharingCaptureIntervalRequest, metrics: ScreenSharingMetrics
  ) {
    overrideFramesPerSecond = override
    metrics.label("captureRequestedMinimumFrameIntervalFPS", String(request.requestedFramesPerSecond))
    metrics.label(
      "captureRequestedFrameIntervalOverride", request.isOverride ? String(request.requestedFramesPerSecond) : "none")
  }
}
