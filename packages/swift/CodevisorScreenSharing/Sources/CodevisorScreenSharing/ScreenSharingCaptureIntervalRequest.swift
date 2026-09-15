import CoreMedia
import Foundation

/// The ScreenCaptureKit minimum-frame-interval REQUEST, isolated from the
/// negotiated video/encoder rate. Without an override the request equals the
/// video rate (existing behaviour). An override must be at least the video
/// rate and at most 120 fps. This describes what is asked of ScreenCaptureKit;
/// it never implies that frames complete at that cadence.
public struct ScreenSharingCaptureIntervalRequest: Equatable, Sendable {
  public static let maximumFramesPerSecond = 120

  public let videoFramesPerSecond: Int
  public let requestedFramesPerSecond: Int
  public var isOverride: Bool { requestedFramesPerSecond != videoFramesPerSecond }
  public var minimumFrameInterval: CMTime { CMTime(value: 1, timescale: Int32(requestedFramesPerSecond)) }

  public init(videoFramesPerSecond: Int, overrideFramesPerSecond: Int?) throws {
    guard videoFramesPerSecond > 0 else { throw ScreenSharingError.invalid("Video frame rate must be positive.") }
    self.videoFramesPerSecond = videoFramesPerSecond
    guard let override = overrideFramesPerSecond else {
      self.requestedFramesPerSecond = videoFramesPerSecond
      return
    }
    guard override >= videoFramesPerSecond, override <= Self.maximumFramesPerSecond else {
      throw ScreenSharingError.invalid(
        "Capture interval request must be at least the video rate (\(videoFramesPerSecond)) and at most "
          + "\(Self.maximumFramesPerSecond) fps.")
    }
    self.requestedFramesPerSecond = override
  }
}
