public struct ScreenSharingTransportEstimate: Equatable, Sendable {
  private struct JitterTotals: Equatable {
    let stream: Substring
    let delaySeconds: Double
    let emitted: Double
  }

  private static let emittedSuffix = ".jitterBufferEmittedCount"

  public private(set) var networkUs: Int64?
  public private(set) var jitterBufferUs: Int64?
  private var previousTotals: JitterTotals?

  public init() {}

  public mutating func update(statistics: [String: String]) {
    if let roundTrip = roundTripSeconds(statistics) {
      networkUs = Int64((roundTrip * 1_000_000 / 2).rounded())
    }
    guard let totals = jitterTotals(statistics) else { return }

    if let previous = previousTotals, previous.stream == totals.stream, totals.emitted > previous.emitted {
      let perFrame = (totals.delaySeconds - previous.delaySeconds) / (totals.emitted - previous.emitted)
      jitterBufferUs = Int64((max(0, perFrame) * 1_000_000).rounded())
    }
    previousTotals = totals
  }

  private func roundTripSeconds(_ statistics: [String: String]) -> Double? {
    statistics.first { $0.key.hasPrefix("candidate-pair.") && $0.key.hasSuffix(".currentRoundTripTime") }
      .flatMap { Double($0.value) }
  }

  private func jitterTotals(_ statistics: [String: String]) -> JitterTotals? {
    let busiest = statistics.compactMap { entry -> (stream: Substring, emitted: Double)? in
      guard entry.key.hasPrefix("inbound-rtp."), entry.key.hasSuffix(Self.emittedSuffix),
        let emitted = Double(entry.value)
      else { return nil }
      return (entry.key.dropLast(Self.emittedSuffix.count), emitted)
    }.max { $0.emitted < $1.emitted }
    guard let busiest, let delay = statistics[busiest.stream + ".jitterBufferDelay"].flatMap(Double.init) else {
      return nil
    }
    return JitterTotals(stream: busiest.stream, delaySeconds: delay, emitted: busiest.emitted)
  }
}
