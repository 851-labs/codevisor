public struct BenchLossModel: Sendable {
  private let continueBurstProbability: Double
  private let startBurstProbability: Double
  private var random: SplitMix64
  private var bursting = false

  public init(lossPercent: Double, averageBurstLength: Int? = nil, seed: UInt64) {
    let loss = lossPercent / 100
    precondition((0..<1).contains(loss), "Loss must be at least 0% and below 100%")
    random = SplitMix64(seed: seed)
    guard let averageBurstLength else {
      continueBurstProbability = loss
      startBurstProbability = loss
      return
    }

    precondition(Double(averageBurstLength) > (loss / (1 - loss)).rounded(.up), "Bursts too short for this loss rate")
    continueBurstProbability = 1 - 1 / Double(averageBurstLength)
    startBurstProbability = loss / (1 - loss) / Double(averageBurstLength)
  }

  public mutating func dropsNextPacket() -> Bool {
    let probability = bursting ? continueBurstProbability : startBurstProbability
    bursting = random.nextUnitInterval() < probability
    return bursting
  }
}
