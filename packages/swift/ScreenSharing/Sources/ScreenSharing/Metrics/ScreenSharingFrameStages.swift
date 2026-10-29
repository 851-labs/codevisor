public struct ScreenSharingFrameStages: Codable, Equatable, Sendable {
  public var capture: Int64?
  public var hostQueue: Int64?
  public var encode: Int64?
  public var network: Int64?
  public var jitterBuffer: Int64?
  public var decode: Int64?
  public var delivery: Int64?
  public var renderQueue: Int64?
  public var present: Int64?

  public init() {}

  public subscript(stage: ScreenSharingFrameStage) -> Int64? {
    switch stage {
    case .capture: capture
    case .hostQueue: hostQueue
    case .encode: encode
    case .network: network
    case .jitterBuffer: jitterBuffer
    case .decode: decode
    case .delivery: delivery
    case .renderQueue: renderQueue
    case .present: present
    }
  }

  public var sum: Int64? {
    var total: Int64 = 0
    for stage in ScreenSharingFrameStage.allCases {
      guard let duration = self[stage] else { return nil }
      total += duration
    }
    return total
  }
}
