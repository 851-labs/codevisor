import Foundation

public enum BenchPacketFate: Sendable, Equatable {
  case delivered(atNs: Int64)
  case lost
  case queueOverflow
}

public struct BenchNetworkModel: Sendable {
  private static let jitterSeedSalt: UInt64 = 0xA5A5_5A5A_C3C3_3C3C

  public let conditions: BenchNetworkConditions
  private var loss: BenchLossModel
  private var jitter: SplitMix64
  private var link: BenchLinkQueue
  private var lastArrivalNs: Int64 = .min

  public init(conditions: BenchNetworkConditions, seed: UInt64) {
    self.conditions = conditions
    loss = BenchLossModel(
      lossPercent: conditions.lossPercent, averageBurstLength: conditions.averageBurstLossLength, seed: seed)
    jitter = SplitMix64(seed: seed ^ Self.jitterSeedSalt)
    link = BenchLinkQueue(capacityKbps: conditions.linkCapacityKbps, lengthPackets: conditions.queueLengthPackets)
  }

  public mutating func send(byteCount: Int, atNs sentNs: Int64) -> BenchPacketFate {
    let isLost = loss.dropsNextPacket()
    guard let departureNs = link.enqueue(byteCount: byteCount, atNs: sentNs) else { return .queueOverflow }
    guard !isLost else { return .lost }

    lastArrivalNs = max(departureNs + delayNs(), lastArrivalNs)
    return .delivered(atNs: lastArrivalNs)
  }

  private mutating func delayNs() -> Int64 {
    var delayMs = conditions.delayMs
    if conditions.delayStandardDeviationMs > 0 {
      delayMs += conditions.delayStandardDeviationMs * standardNormal()
    }
    return Int64((max(delayMs, 0) * 1_000_000).rounded())
  }

  private mutating func standardNormal() -> Double {
    let radius = (-2 * log(1 - jitter.nextUnitInterval())).squareRoot()
    return radius * cos(2 * .pi * jitter.nextUnitInterval())
  }
}
