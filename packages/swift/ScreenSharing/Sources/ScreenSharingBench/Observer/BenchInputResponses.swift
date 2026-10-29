public struct BenchInputResponses: Sendable, Equatable {
  public let delaysMs: [Double]
  public let unansweredEvents: Int

  public init(eventsNs: [Int64], observations: [BenchObservation]) {
    let frames = observations.filter { $0.version != nil }.sorted { $0.ptsNs < $1.ptsNs }
    let events = eventsNs.sorted()
    var delays: [Double] = []
    var previousSettled = true
    for (index, eventNs) in events.enumerated() {
      let nextEventNs = events.dropFirst(index + 1).first
      let responseNs = Self.responseNs(after: eventNs, in: frames)
      let settled = responseNs.map { response in nextEventNs.map { response < $0 } ?? true } ?? false
      if previousSettled, settled, let responseNs { delays.append(Double(responseNs - eventNs) / 1_000_000) }
      previousSettled = settled
    }
    delaysMs = delays
    unansweredEvents = events.count - delays.count
  }

  private static func responseNs(after eventNs: Int64, in frames: [BenchObservation]) -> Int64? {
    guard let shown = frames.last(where: { $0.ptsNs <= eventNs })?.version else { return nil }

    return frames.first { $0.ptsNs > eventNs && $0.version != shown }?.ptsNs
  }
}
