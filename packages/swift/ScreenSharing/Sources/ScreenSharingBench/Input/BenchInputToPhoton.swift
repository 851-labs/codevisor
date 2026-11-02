public struct BenchInputToPhoton: Sendable, Equatable {
  public let events: Int
  public let delaysMs: [Double]
  public let answered: BenchDistribution?
  public let unansweredEvents: Int
  public let byKind: [BenchInputKind: BenchDistribution]

  public init(events: [BenchInputEvent], observations: [BenchObservation]) {
    let responses = BenchInputResponses(eventsNs: events.map(\.postedNs), observations: observations)
    let kinds = Dictionary(events.map { ($0.postedNs, $0.kind) }, uniquingKeysWith: { first, _ in first })
    self.events = events.count
    delaysMs = responses.delaysMs
    answered = BenchDistribution(delaysMs)
    unansweredEvents = responses.unansweredEvents
    byKind = Dictionary(grouping: responses.answers) { kinds[$0.eventNs] ?? .key }
      .compactMapValues { BenchDistribution($0.map(\.delayMs)) }
  }
}
