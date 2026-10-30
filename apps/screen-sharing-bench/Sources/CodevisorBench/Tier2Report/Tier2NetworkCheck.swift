enum Tier2NetworkCheck {
  static func describe(_ check: [String: JSONValue]?) -> String {
    guard let check, let probes = check["probes"]?.number, probes > 0, let replies = check["replies"]?.number else {
      return "–"
    }
    guard replies > 0 else { return "no replies" }

    let roundTrip = check["burst_minimum_round_trip_ms"]?["p50"]?.number.map { Tier2Format.number($0) } ?? "–"
    let loss = (1 - replies / probes) * 100
    return "RTT \(roundTrip) ms, \(Tier2Format.number(loss))% lost"
  }
}
