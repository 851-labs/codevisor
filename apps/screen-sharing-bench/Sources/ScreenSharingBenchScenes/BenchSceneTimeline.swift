public enum BenchSceneTimeline: Sendable, Equatable {
  case everyTick
  case everyTicks(Int)
  case typing
  case inputDriven

  public static let ticksPerSecond = BenchSceneTiming.ticksPerSecond

  public func version(atTick tick: Int) -> Int {
    switch self {
    case .everyTick: tick
    case .everyTicks(let interval): tick / interval
    case .typing: Self.charactersTyped(byTick: tick)
    case .inputDriven: 0
    }
  }

  private static func charactersTyped(byTick tick: Int) -> Int {
    let cycles = tick / BenchSceneTiming.typingCycleTicks
    return cycles * charactersTyped(withinCycle: BenchSceneTiming.typingCycleTicks)
      + charactersTyped(withinCycle: tick % BenchSceneTiming.typingCycleTicks)
  }

  private static func charactersTyped(withinCycle tick: Int) -> Int {
    let steady = min(tick, BenchSceneTiming.burstStartTick) / BenchSceneTiming.typingTicksPerCharacter
    let burst = max(0, tick - BenchSceneTiming.burstStartTick) / BenchSceneTiming.burstTicksPerCharacter
    return steady + burst
  }
}
