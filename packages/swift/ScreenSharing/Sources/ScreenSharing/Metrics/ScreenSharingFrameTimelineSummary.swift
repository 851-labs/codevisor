public struct ScreenSharingFrameTimelineSummary: Codable, Equatable, Sendable {
  public static let formatVersion = 1

  public let version: Int
  public let frames: Int
  public let incompleteFrames: Int
  public let unpresentedFrames: Int
  public let stages: [String: ScreenSharingMetrics.Timing]
  public let stageSum: ScreenSharingMetrics.Timing?
  public let captureToPresent: ScreenSharingMetrics.Timing?
  public let residual: ScreenSharingMetrics.Timing?

  init?(records: [ScreenSharingFrameRecord], unpresentedFrames: Int) {
    guard !records.isEmpty else { return nil }

    let complete = records.filter { $0.stageSumUs != nil }
    let sameClock = complete.filter { $0.captureToPresentUs != nil }
    version = Self.formatVersion
    frames = complete.count
    incompleteFrames = records.count - complete.count
    self.unpresentedFrames = unpresentedFrames
    stages = Self.stageTimings(complete)
    stageSum = Self.optionalTiming(complete.compactMap(\.stageSumUs))
    captureToPresent = Self.optionalTiming(sameClock.compactMap(\.captureToPresentUs))
    residual = Self.optionalTiming(sameClock.compactMap(Self.residualUs))
  }

  private static func stageTimings(_ records: [ScreenSharingFrameRecord]) -> [String: ScreenSharingMetrics.Timing] {
    var timings: [String: ScreenSharingMetrics.Timing] = [:]
    for stage in ScreenSharingFrameStage.allCases {
      timings[stage.rawValue] = optionalTiming(records.compactMap { $0.stagesUs[stage] })
    }
    return timings
  }

  private static func residualUs(_ record: ScreenSharingFrameRecord) -> Int64? {
    guard let measured = record.captureToPresentUs, let sum = record.stageSumUs else { return nil }
    return measured - sum
  }

  private static func optionalTiming(_ microseconds: [Int64]) -> ScreenSharingMetrics.Timing? {
    microseconds.isEmpty ? nil : timing(microseconds)
  }

  private static func timing(_ microseconds: [Int64]) -> ScreenSharingMetrics.Timing {
    ScreenSharingMetrics.timing(microseconds.map { Double($0) / 1000 })
  }
}
