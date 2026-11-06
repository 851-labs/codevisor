struct BotMascotMotionPacer {
  static let settle: Duration = .seconds(1)
  static let minimumHold: Duration = .seconds(4)

  private var mode: String?
  private var since: ContinuousClock.Instant?

  func wait(before motion: BotMascotMotion, at now: ContinuousClock.Instant) -> Duration {
    guard let since, motion.riveMode != mode else { return .zero }

    return max(since + Self.minimumHold - now, Self.settle)
  }

  mutating func shown(_ motion: BotMascotMotion, at now: ContinuousClock.Instant) {
    guard motion.riveMode != mode else { return }

    mode = motion.riveMode
    since = now
  }
}
