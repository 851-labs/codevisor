import CoreMedia
import Testing

@testable import ScreenSharing

@Suite struct ScreenSharingCaptureIntervalRequestTests {
  @Test func defaultRequestEqualsTheVideoRateAndIsNotAnOverride() throws {
    let request = try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: 60, overrideFramesPerSecond: nil)
    #expect(request.requestedFramesPerSecond == 60 && !request.isOverride)
    #expect(request.minimumFrameInterval == CMTime(value: 1, timescale: 60))
  }

  @Test func overrideIsBoundedByTheVideoRateAndOneHundredTwenty() throws {
    let request = try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: 60, overrideFramesPerSecond: 120)
    #expect(request.requestedFramesPerSecond == 120 && request.isOverride)
    #expect(request.minimumFrameInterval == CMTime(value: 1, timescale: 120))
    let same = try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: 60, overrideFramesPerSecond: 60)
    #expect(!same.isOverride)  // an override equal to the video rate is the existing request
    for bad in [59, 30, 0, -1, 121, 240] {
      #expect(throws: ScreenSharingError.self) {
        try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: 60, overrideFramesPerSecond: bad)
      }
    }
    for badVideo in [0, -30] {
      #expect(throws: ScreenSharingError.self) {
        try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: badVideo, overrideFramesPerSecond: nil)
      }
    }
  }

  /// Policy regression for configuration updates: a request valid at start (video 30 + override
  /// 30) must be re-evaluated when the video rate changes; at video 60 the same override is
  /// invalid and construction throws — the capture must not silently request 60 while the
  /// request telemetry still says 30.
  @Test func anOverrideValidAtStartBecomesInvalidWhenTheVideoRateRisesAboveIt() throws {
    let override = 30
    let atStart = try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: 30, overrideFramesPerSecond: override)
    #expect(atStart.requestedFramesPerSecond == 30 && !atStart.isOverride)
    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: 60, overrideFramesPerSecond: override)
    }
    // The assigned experiment stays valid across the same update: 120 over video 30 and over video 60.
    let experiment30 = try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: 30, overrideFramesPerSecond: 120)
    let experiment60 = try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: 60, overrideFramesPerSecond: 120)
    #expect(experiment30.requestedFramesPerSecond == 120 && experiment60.requestedFramesPerSecond == 120)
    #expect(experiment30 != experiment60)  // the video rate is part of the request identity
  }
}
