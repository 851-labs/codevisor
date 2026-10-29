import ScreenSharingBench

struct ClockResponderCheck: CalibrationCheck {
  private static let idleExits = 0...3600
  private static let checkInterval = Duration.seconds(1)

  private let port: UInt16
  private let duration: Duration
  private let idleExitNs: Int64?

  init(options: BenchOptions, port: UInt16) throws {
    self.port = port
    duration = .seconds(try options.integer("duration", default: 660, in: ClockProbeCheck.durations))
    let idleExit = try options.integer("idle-exit", default: 0, in: Self.idleExits)
    idleExitNs = idleExit == 0 ? nil : Int64(idleExit) * 1_000_000_000
  }

  func run() async throws {
    let responder = try BenchClockProbeResponder(port: port)
    responder.start()
    defer { responder.stop() }

    BenchConsole.error("clock probe responder listening on UDP port \(responder.port)")
    let clock = ContinuousClock()
    let end = clock.now + duration
    while clock.now < end, !isIdle(responder) {
      try await clock.sleep(for: Self.checkInterval)
    }
    try BenchOutput.print(ClockResponderResult(responder))
  }

  private func isIdle(_ responder: BenchClockProbeResponder) -> Bool {
    guard let idleExitNs, let lastAnswerNs = responder.lastAnswerNs else { return false }

    return BenchMachClock.nowNs() - lastAnswerNs > idleExitNs
  }
}

private struct ClockResponderResult: Encodable {
  let check = "c2"
  let role = "responder"
  let port: UInt16
  let answeredProbes: Int
  let failedReceivesAndReplies: Int
  let lastError: String?

  init(_ responder: BenchClockProbeResponder) {
    port = responder.port
    answeredProbes = responder.answeredProbes
    failedReceivesAndReplies = responder.failedReceivesAndReplies
    lastError = responder.lastError.map { "\($0)" }
  }
}
