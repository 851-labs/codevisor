enum BenchSceneTiming {
  static let ticksPerSecond = 60
  static let caretToggleTicks = 15
  static let cardTicks = 3 * ticksPerSecond
  static let typingTicksPerCharacter = 6
  static let burstTicksPerCharacter = 2
  static let typingCycleTicks = 20 * ticksPerSecond
  static let burstStartTick = 15 * ticksPerSecond
  static let scrollPointsPerTick = 10
  static let pageDownTicks = 5 * ticksPerSecond
  static let windowDragPointsPerSecond = 1000.0
}
