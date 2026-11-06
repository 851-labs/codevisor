struct ScreenSharingV2EncoderRoute: Sendable, Equatable {
  enum Choice: String, Sendable {
    case fast
    case slow
  }

  static let fastFromBitrate = 30_000_000
  static let fastFromEstimate = 60_000_000
  static let slowBelowBitrate = 8_000_000
  static let fastAfterNs: Int64 = 5_000_000_000
  static let fastAgainAfterNs: Int64 = 30_000_000_000
  static let slowAfterNs: Int64 = 1_000_000_000
  static let feedbackFreshNs: Int64 = 1_000_000_000
  static let slowEvidenceFreshNs: Int64 = 500_000_000
  static let slowBelowEstimate = Int(Double(slowBelowBitrate) / 0.85)
  static let queuedAboveMs = 50.0
  static let heavyLoss = 0.1
  static let shortestRoundTripKeptNs: Int64 = 10_000_000_000

  private(set) var choice = Choice.slow
  private var bitrate: Int
  private var wantedSinceNs: Int64?
  private var feedbackNs: Int64?
  private var feedbackEstimate = Int.max
  private var feedbackConfirmsSlow = false
  private var shortestRoundTrip = ScreenSharingV2WindowedMinimum(windowNs: shortestRoundTripKeptNs)
  private var lastRoundTripMs: Double?
  private var movedToSlow = false

  init(bitrate: Int, atNs nowNs: Int64) {
    self.bitrate = bitrate
    wantedSinceNs = wanted == nil ? nil : nowNs
  }

  var switchDueNs: Int64? {
    guard let wanted, let wantedSinceNs else { return nil }

    return wantedSinceNs + holdNs(before: wanted)
  }

  mutating func observe(bitrate: Int, atNs nowNs: Int64) {
    let wantedBefore = wanted
    self.bitrate = bitrate
    guard wanted != wantedBefore else { return }

    wantedSinceNs = wanted == nil ? nil : nowNs
  }

  mutating func observe(_ feedback: ScreenSharingTileNetworkFeedback, atNs nowNs: Int64) {
    let roundTripMs = feedback.roundTripDelayMs
    guard roundTripMs >= 0 else { return }

    feedbackNs = nowNs
    feedbackEstimate = feedback.transmissionBitsPerSecond
    let queued = roundTripMs > shortestRoundTrip.observe(roundTripMs, atNs: nowNs) + Self.queuedAboveMs
    let settled = lastRoundTripMs.map { abs(roundTripMs - $0) <= Self.queuedAboveMs } ?? true
    lastRoundTripMs = roundTripMs
    let struggling = queued || feedback.packetErrorRate >= Self.heavyLoss
    feedbackConfirmsSlow = feedbackEstimate < Self.slowBelowEstimate && struggling
    let provenFast = feedbackEstimate >= Self.fastFromEstimate
    if wanted == .fast, queued || !settled || !provenFast { wantedSinceNs = nowNs }
  }

  mutating func update(atNs nowNs: Int64) -> Bool {
    guard let wanted, let switchDueNs, nowNs >= switchDueNs, hasEvidence(for: wanted, atNs: nowNs) else {
      return false
    }

    choice = wanted
    wantedSinceNs = nil
    movedToSlow = movedToSlow || wanted == .slow
    return true
  }

  private var wanted: Choice? {
    switch choice {
    case .slow: bitrate >= Self.fastFromBitrate ? .fast : nil
    case .fast: bitrate < Self.slowBelowBitrate ? .slow : nil
    }
  }

  private func hasEvidence(for choice: Choice, atNs nowNs: Int64) -> Bool {
    switch choice {
    case .fast: hasFeedback(within: Self.feedbackFreshNs, atNs: nowNs)
    case .slow: hasFeedback(within: Self.slowEvidenceFreshNs, atNs: nowNs) && feedbackConfirmsSlow
    }
  }

  private func hasFeedback(within freshNs: Int64, atNs nowNs: Int64) -> Bool {
    feedbackNs.map { nowNs - $0 <= freshNs } ?? false
  }

  private func holdNs(before choice: Choice) -> Int64 {
    switch choice {
    case .fast: movedToSlow ? Self.fastAgainAfterNs : Self.fastAfterNs
    case .slow: Self.slowAfterNs
    }
  }
}
