public struct BenchRelayStatistics: Codable, Sendable, Equatable {
  public static let firstLossesKept = 16

  public var packets = 0
  public var bytes = 0
  public var lost = 0
  public var queueOverflow = 0
  public var sendFailures = 0
  public var firstLosses: [Int] = []

  public init() {}

  mutating func record(_ fate: BenchPacketFate, byteCount: Int) {
    let index = packets
    packets += 1
    bytes += byteCount
    switch fate {
    case .delivered: return
    case .lost:
      lost += 1
      if firstLosses.count < Self.firstLossesKept { firstLosses.append(index) }
    case .queueOverflow: queueOverflow += 1
    }
  }
}
