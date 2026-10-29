import ScreenSharingBench

struct ClockProberCheck: CalibrationCheck {
  private static let intervals = 1...60

  let presentsWindows = false
  private let responder: BenchUDPAddress
  private let duration: Duration
  private let interval: Duration
  private let output: String?

  init(options: BenchOptions, responder: BenchUDPAddress) throws {
    self.responder = responder
    duration = .seconds(try options.integer("duration", default: 600, in: ClockProbeCheck.durations))
    interval = .seconds(try options.integer("interval", default: 2, in: Self.intervals))
    output = try options.string("output")
  }

  func run() async throws {
    let client = try BenchClockProbeClient(responder: responder)
    let bursts = try await probe(client)
    if let output { try BenchOutput.writeLines(ClockProbeRecord.records(bursts), to: output) }

    let result = ClockProbeResult(responder: responder, duration: duration, bursts: bursts, lastError: client.lastError)
    try BenchOutput.print(result)
    guard result.passed else { throw CalibrationFailed(check: result.check) }
  }

  private func probe(_ client: BenchClockProbeClient) async throws -> [[BenchClockExchange]] {
    let clock = ContinuousClock()
    let end = clock.now + duration
    var next = clock.now
    var bursts: [[BenchClockExchange]] = []
    while next < end {
      bursts.append(await Self.burst(client))
      next += interval
      try await clock.sleep(until: next)
    }
    return bursts
  }

  @concurrent
  private nonisolated static func burst(_ client: BenchClockProbeClient) async -> [BenchClockExchange] {
    client.burst()
  }
}
