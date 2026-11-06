import Foundation

public struct ScreenSharingTimelineBreakdown: Equatable, Sendable {
  public struct Row: Equatable, Sendable, Identifiable {
    public let label: String
    public let timing: ScreenSharingMetrics.Timing

    public var id: String { label }
    public var value: String { String(format: "%.1f / %.1f ms", timing.p50Ms, timing.p95Ms) }
    public var p50: String { String(format: "%.1f ms", timing.p50Ms) }
    public var p95: String { String(format: "%.1f ms", timing.p95Ms) }
  }

  private static let labels: [ScreenSharingFrameStage: String] = [
    .capture: "Capture", .hostQueue: "Host queue", .encode: "Encode", .handOff: "Hand-off", .network: "Network",
    .assemble: "Assemble", .decode: "Decode", .delivery: "Deliver", .renderQueue: "Render queue",
    .present: "Commit → screen",
  ]

  public let stages: [Row]
  public let total: Row?
  public let frames: Int

  public var caption: String {
    "The last \(frames) frames. Network is half the round trip."
  }

  init?(_ summary: ScreenSharingFrameTimelineSummary) {
    guard summary.frames > 0 else { return nil }

    stages = ScreenSharingFrameStage.allCases.compactMap { stage in
      guard let label = Self.labels[stage], let timing = summary.stages[stage.rawValue] else { return nil }
      return Row(label: label, timing: timing)
    }
    total =
      summary.captureToPresent.map { Row(label: "Capture → screen", timing: $0) }
      ?? summary.stageSum.map { Row(label: "Sum of stages", timing: $0) }
    frames = summary.frames
  }
}
