public struct BenchNetworkConditions: Sendable, Equatable {
  public static let n0 = BenchNetworkConditions(id: "N0")
  public static let n1 = BenchNetworkConditions(id: "N1", delayMs: 1, linkCapacityKbps: 1_000_000)
  public static let n2 = BenchNetworkConditions(
    id: "N2", delayMs: 5, delayStandardDeviationMs: 3, lossPercent: 0.5, linkCapacityKbps: 200_000)
  public static let n3 = BenchNetworkConditions(id: "N3", delayMs: 1, lossPercent: 1, linkCapacityKbps: 1_000_000)
  public static let n4 = BenchNetworkConditions(
    id: "N4", delayMs: 1, lossPercent: 1, averageBurstLossLength: 5, linkCapacityKbps: 1_000_000)
  public static let n5 = BenchNetworkConditions(
    id: "N5", delayMs: 10, linkCapacityKbps: 30_000, queueLengthPackets: 30)
  public static let n6 = BenchNetworkConditions(
    id: "N6", delayMs: 25, delayStandardDeviationMs: 5, lossPercent: 0.1, linkCapacityKbps: 50_000)
  public static let n7 = BenchNetworkConditions(id: "N7", delayMs: 50, lossPercent: 5, linkCapacityKbps: 1_000)
  public static let matrix: [BenchNetworkConditions] = [.n0, .n1, .n2, .n3, .n4, .n5, .n6, .n7]

  public var id: String
  public var delayMs: Double
  public var delayStandardDeviationMs: Double
  public var lossPercent: Double
  public var averageBurstLossLength: Int?
  public var linkCapacityKbps: Int?
  public var queueLengthPackets: Int?

  public init(
    id: String, delayMs: Double = 0, delayStandardDeviationMs: Double = 0, lossPercent: Double = 0,
    averageBurstLossLength: Int? = nil, linkCapacityKbps: Int? = nil, queueLengthPackets: Int? = nil
  ) {
    self.id = id
    self.delayMs = delayMs
    self.delayStandardDeviationMs = delayStandardDeviationMs
    self.lossPercent = lossPercent
    self.averageBurstLossLength = averageBurstLossLength
    self.linkCapacityKbps = linkCapacityKbps
    self.queueLengthPackets = queueLengthPackets
  }
}
