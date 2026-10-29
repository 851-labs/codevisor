import ScreenSharingBench

struct ClockProbeResult: Encodable {
  static let maximumEpsilonMs = 0.5
  static let maximumResidualMs = 0.2
  static let maximumRejectedFraction = 0.05

  let check = "c2"
  let responder: String
  let durationS: Int64
  let bursts: Int
  let probes: Int
  let replies: Int
  let rejectedSlowBursts: Int?
  let epsilonMs: Double?
  let residualMs: Double?
  let residualWindowS: Int64
  let linearResidualMs: Double?
  let driftPpm: Double?
  let offsetMs: Double?
  let burstMinimumRoundTripMs: BenchDistribution?
  let roundTripMs: BenchDistribution?
  let lastError: String?
  let passed: Bool

  init(responder: BenchUDPAddress, duration: Duration, bursts: [[BenchClockExchange]], lastError: (any Error)?) {
    let answered = bursts.filter { !$0.isEmpty }
    let track = BenchClockTrack(bursts: answered)
    self.responder = responder.description
    durationS = duration.components.seconds
    self.bursts = bursts.count
    probes = bursts.count * BenchClockProbeClient.probesPerBurst
    replies = bursts.map(\.count).reduce(0, +)
    rejectedSlowBursts = track?.rejectedBursts
    epsilonMs = track?.quality.epsilonMs
    residualMs = track?.quality.residualMs
    residualWindowS = 2 * BenchClockTrack.defaultHalfWindowNs / 1_000_000_000
    linearResidualMs = track?.linearResidualMs
    driftPpm = track?.quality.driftPpm
    offsetMs = track.map { $0.offsetNs(atLocal: answered[0][0].localSendNs) / 1_000_000 }
    burstMinimumRoundTripMs = BenchDistribution(answered.compactMap { $0.map(Self.roundTripMs).min() })
    roundTripMs = BenchDistribution(answered.flatMap { $0.map(Self.roundTripMs) })
    self.lastError = lastError.map { "\($0)" }
    passed = track.map { Self.passes($0, bursts: answered.count) } ?? false
  }

  private static func roundTripMs(_ exchange: BenchClockExchange) -> Double {
    Double(exchange.roundTripNs) / 1_000_000
  }

  private static func passes(_ track: BenchClockTrack, bursts: Int) -> Bool {
    let rejectedFraction = Double(track.rejectedBursts) / Double(max(bursts, 1))
    return track.quality.epsilonMs <= maximumEpsilonMs && track.quality.residualMs <= maximumResidualMs
      && rejectedFraction <= maximumRejectedFraction
  }
}
