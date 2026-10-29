struct BenchLinkQueue {
  private let capacityKbps: Int?
  private let lengthPackets: Int?
  private var departuresNs: [Int64] = []
  private var linkFreeNs: Int64 = .min

  init(capacityKbps: Int?, lengthPackets: Int?) {
    self.capacityKbps = capacityKbps
    self.lengthPackets = lengthPackets
  }

  mutating func enqueue(byteCount: Int, atNs sentNs: Int64) -> Int64? {
    departuresNs.removeAll { $0 <= sentNs }
    guard !isFull else { return nil }

    linkFreeNs = max(sentNs, linkFreeNs) + serializationNs(byteCount: byteCount)
    if lengthPackets != nil { departuresNs.append(linkFreeNs) }
    return linkFreeNs
  }

  private var isFull: Bool {
    guard let lengthPackets else { return false }

    return departuresNs.count >= lengthPackets
  }

  private func serializationNs(byteCount: Int) -> Int64 {
    guard let capacityKbps else { return 0 }

    return Int64(byteCount) * 8 * 1_000_000 / Int64(capacityKbps)
  }
}
