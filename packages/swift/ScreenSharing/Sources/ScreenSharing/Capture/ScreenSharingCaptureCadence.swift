import CoreMedia

public struct ScreenSharingCaptureCadence: Equatable, Sendable {
  public static let slowDisplayFramesPerSecondCap = 480
  public static let maximumFramesPerSecond = 60.0
  public static let fastDisplayHeadroom = 16.0 / 15.0
  static let unknownDisplayRefreshHz = 120.0
  private static let slowDisplayTolerance = 0.5

  public let displayRefreshHz: Double
  public let minimumFrameInterval: CMTime

  public init(displayRefreshHz: Double?) {
    let refresh = displayRefreshHz.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Self.unknownDisplayRefreshHz
    self.displayRefreshHz = refresh
    guard refresh > Self.maximumFramesPerSecond + Self.slowDisplayTolerance else {
      minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.slowDisplayFramesPerSecondCap))
      return
    }

    let refreshesPerFrame = (refresh / Self.maximumFramesPerSecond).rounded(.up)
    let cap = refresh / refreshesPerFrame * Self.fastDisplayHeadroom
    minimumFrameInterval = CMTime(value: Int64((1_000_000_000 / cap).rounded()), timescale: 1_000_000_000)
  }

  public func minimumFrameInterval(requesting framesPerSecond: Int) -> CMTime {
    guard Double(framesPerSecond) < Self.maximumFramesPerSecond else { return minimumFrameInterval }

    return CMTime(value: 1, timescale: CMTimeScale(max(1, framesPerSecond)))
  }

  public var framesPerSecond: Double {
    min(displayRefreshHz, displayRefreshHz / (displayRefreshHz / Self.maximumFramesPerSecond).rounded(.up))
  }
}
