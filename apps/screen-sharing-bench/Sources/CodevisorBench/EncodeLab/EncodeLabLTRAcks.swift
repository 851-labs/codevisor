struct EncodeLabLTRAcks {
  static let roundTripNs: Int64 = 33_333_333

  private var pending: [(token: Int, dueNs: Int64)] = []

  mutating func received(token: Int, atNs: Int64) {
    pending.append((token, atNs + Self.roundTripNs))
  }

  mutating func takeDue(atNs: Int64) -> [Int] {
    let due = pending.filter { $0.dueNs <= atNs }.map(\.token)
    pending.removeAll { $0.dueNs <= atNs }
    return due
  }
}
