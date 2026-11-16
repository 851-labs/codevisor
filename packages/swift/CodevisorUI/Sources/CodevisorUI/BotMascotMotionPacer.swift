struct BotMascotMotionPacer {
  static let settle: Duration = .seconds(1)
  static let minimumHold: Duration = .seconds(4)

  private var mode: String?
  private var since: ContinuousClock.Instant?
  private var isFirstMode = true

  func wait(before motion: BotMascotMotion, at now: ContinuousClock.Instant) -> Duration {
    guard let since, motion.riveMode != mode else { return .zero }
    guard !isFirstMode else { return Self.settle }

    return max(since + Self.minimumHold - now, Self.settle)
  }

  mutating func shown(_ motion: BotMascotMotion, at now: ContinuousClock.Instant) {
    guard motion.riveMode != mode else { return }

    isFirstMode = mode == nil
    mode = motion.riveMode
    since = now
  }
}
