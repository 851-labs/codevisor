struct ScreenSharingV2EncoderRoute: Sendable, Equatable {
  enum Choice: String, Sendable {
    case fast
    case slow
  }

  static let fastFromBitrate = 12_000_000
  static let slowBelowBitrate = 8_000_000
  static let fastAfterNs: Int64 = 5_000_000_000
  static let slowAfterNs: Int64 = 1_000_000_000
  static let feedbackFreshNs: Int64 = 1_000_000_000
  static let queuedAboveMs = 50.0
  static let shortestRoundTripKeptNs: Int64 = 10_000_000_000

  private(set) var choice = Choice.slow
  private var bitrate: Int
  private var wantedSinceNs: Int64?
  private var feedbackNs: Int64?
  private var shortestRoundTripMs: Double?
  private var shortestRoundTripNs: Int64 = 0

  init(bitrate: Int, atNs nowNs: Int64) {
    self.bitrate = bitrate
    wantedSinceNs = wanted == nil ? nil : nowNs
  }

  var switchDueNs: Int64? {
    guard let wanted, let wantedSinceNs else { return nil }

    return wantedSinceNs + Self.holdNs(before: wanted)
  }

  mutating func observe(bitrate: Int, atNs nowNs: Int64) {
    let wantedBefore = wanted
    self.bitrate = bitrate
    guard wanted != wantedBefore else { return }

    wantedSinceNs = wanted == nil ? nil : nowNs
  }

  mutating func observe(roundTripMs: Double, atNs nowNs: Int64) {
    guard roundTripMs > 0 else { return }

    feedbackNs = nowNs
    let shortest = shortestRoundTrip(observing: roundTripMs, atNs: nowNs)
    if wanted == .fast, roundTripMs > shortest + Self.queuedAboveMs { wantedSinceNs = nowNs }
  }

  mutating func update(atNs nowNs: Int64) -> Bool {
    guard let wanted, let switchDueNs, nowNs >= switchDueNs, hasEvidence(for: wanted, atNs: nowNs) else {
      return false
    }

    choice = wanted
    wantedSinceNs = nil
    return true
  }

  private var wanted: Choice? {
    switch choice {
    case .slow: bitrate >= Self.fastFromBitrate ? .fast : nil
    case .fast: bitrate < Self.slowBelowBitrate ? .slow : nil
    }
  }

  private mutating func shortestRoundTrip(observing roundTripMs: Double, atNs nowNs: Int64) -> Double {
    let expired = nowNs - shortestRoundTripNs > Self.shortestRoundTripKeptNs
    if let shortestRoundTripMs, roundTripMs > shortestRoundTripMs, !expired { return shortestRoundTripMs }

    shortestRoundTripMs = roundTripMs
    shortestRoundTripNs = nowNs
    return roundTripMs
  }

  private func hasEvidence(for choice: Choice, atNs nowNs: Int64) -> Bool {
    guard choice == .fast else { return true }

    return feedbackNs.map { nowNs - $0 <= Self.feedbackFreshNs } ?? false
  }

  private static func holdNs(before choice: Choice) -> Int64 {
    switch choice {
    case .fast: fastAfterNs
    case .slow: slowAfterNs
    }
  }
}
