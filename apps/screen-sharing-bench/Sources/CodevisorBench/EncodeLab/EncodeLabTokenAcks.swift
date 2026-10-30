struct EncodeLabTokenAcks {
  let roundTripNs: Int64
  private var pending: [(token: Int, dueNs: Int64)] = []

  init(roundTripNs: Int64) {
    self.roundTripNs = roundTripNs
  }

  mutating func received(token: Int, atNs: Int64) {
    pending.append((token, atNs + roundTripNs))
  }

  mutating func takeDue(atNs: Int64) -> [Int] {
    let due = pending.filter { $0.dueNs <= atNs }.map(\.token)
    pending.removeAll { $0.dueNs <= atNs }
    return due
  }
}
