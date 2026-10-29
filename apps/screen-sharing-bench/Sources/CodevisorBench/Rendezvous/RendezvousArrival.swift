struct RendezvousArrival: Codable, Sendable {
  enum Party: String, Codable, CaseIterable, Sendable {
    case host
    case viewer
  }

  static let ready = "ok"

  let barrier: String
  let party: Party
  let status: String

  @MainActor
  init?(options: BenchOptions) throws {
    let barrier = try options.string("barrier")
    let party = try options.string("party")
    let status = try options.string("status", default: Self.ready)
    guard let barrier else { return nil }
    guard let party = party.flatMap(Party.init(rawValue:)) else {
      throw BenchUsageError(message: "--party must be host or viewer")
    }

    self.barrier = barrier
    self.party = party
    self.status = status
  }
}

struct RendezvousMeeting: Codable, Sendable {
  let barrier: String
  let statuses: [String: String]

  var allReady: Bool {
    statuses.values.allSatisfy { $0 == RendezvousArrival.ready }
  }

  var allAgree: Bool {
    Set(statuses.values).count == 1
  }
}
